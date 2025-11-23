#!/usr/bin/env lua

local jsonc  = require("luci.jsonc")
local common = require("oasis.common")
local uci    = require("luci.model.uci").cursor()
local debug  = require("oasis.chat.debug")
local ous    = require("oasis.unified.chat.schema")

local M = {}

-- Anthropic "tool use" detection helpers ------------------------------------
local function detect_anthropic_tool_use_from_content_list(content)
    if type(content) ~= "table" then return false end
    for _, part in ipairs(content) do
        if type(part) == "table" and part.type == "tool_use" then
            return true
        end
    end
    return false
end

function M.detect(message)
    if not message or type(message) ~= "table" then
        return false
    end

    -- OpenAI-like tool_calls fallback (for uniformity in pipeline)
    if message.tool_calls and type(message.tool_calls) == "table" and #message.tool_calls > 0 then
        local tool = message.tool_calls[1]
        if tool and tool["function"] and type(tool["function"]) == "table" then
            if tool["function"].name and tool["function"].arguments then
                return true
            end
        end
    end

    -- Anthropic: message.content is a list of content blocks; detect tool_use
    if message.content and type(message.content) == "table" then
        return detect_anthropic_tool_use_from_content_list(message.content)
    end

    return false
end

-- Execute tool calls and return unified tool_outputs JSON and assistant speaker
function M.process(self, message)
    if not M.detect(message) then
        return nil
    end

    local is_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
    if not is_tool then
        return nil
    end

    debug:log("oasis.log", "recv_ai_msg", "is_tool (local_tool flag is enabled) [anthropic]")
    local client = require("oasis.local.tool.client")

    local function_call = { service = "Anthropic", tool_outputs = {} }
    local first_output_str = ""
    local speaker = { role = "assistant", tool_calls = {} }
    local reboot = false
    local shutdown = false

    -- Case 1: OpenAI-like tool_calls (fallback)
    if message.tool_calls and type(message.tool_calls) == "table" and #message.tool_calls > 0 then
        for _, tc in ipairs(message.tool_calls) do
            local func = tc["function"] and tc["function"].name or ""
            local args = {}
            if tc["function"] and tc["function"].arguments then
                local ok, parsed = pcall(jsonc.parse, tc["function"].arguments)
                if ok and parsed then args = parsed end
            end

            local call_id = tostring(tc.id or "")
            if self and self.processed_tool_call_ids and call_id ~= "" then
                if self.processed_tool_call_ids[call_id] then
                    debug:log("oasis.log", "process", "skip duplicate tool_call id = " .. call_id)
                else
                    self.processed_tool_call_ids[call_id] = true
                    local result = client.exec_server_tool(self:get_format(), func, args)

                    if result.reboot then
                        debug:log("oasis.log", "process", "result.reboot = true")
                        reboot = result.reboot
                    end
                    if result.shutdown then
                        debug:log("oasis.log", "process", "result.shutdown = true")
                        shutdown = result.shutdown
                    end

                    local output = jsonc.stringify(result, false)
                    table.insert(function_call.tool_outputs, {
                        tool_call_id = call_id,
                        output = output,
                        name = func
                    })
                    table.insert(speaker.tool_calls, {
                        id = call_id,
                        type = "function",
                        ["function"] = {
                            name = func,
                            arguments = jsonc.stringify(args or {}, false)
                        }
                    })
                    if first_output_str == "" then first_output_str = output end
                end
            else
                local result = client.exec_server_tool(self:get_format(), func, args)
                local output = jsonc.stringify(result, false)
                table.insert(function_call.tool_outputs, { output = output, name = func })
                table.insert(speaker.tool_calls, {
                    id = "",
                    type = "function",
                    ["function"] = { name = func, arguments = jsonc.stringify(args or {}, false) }
                })
                if first_output_str == "" then first_output_str = output end
            end
        end
    end

    -- Case 2: Anthropic tool_use blocks
    if message.content and type(message.content) == "table" then
        for _, part in ipairs(message.content) do
            if type(part) == "table" and part.type == "tool_use" then
                local func = tostring(part.name or "")
                local args = part.input
                if type(args) ~= "table" then
                    local ok, parsed = pcall(jsonc.parse, tostring(args or ""))
                    if ok and parsed then args = parsed else args = {} end
                end
                local call_id = tostring(part.id or "")

                if self and self.processed_tool_call_ids and call_id ~= "" then
                    if self.processed_tool_call_ids[call_id] then
                        debug:log("oasis.log", "recv_ai_msg", "skip duplicate tool_use id = " .. call_id)
                    else
                        self.processed_tool_call_ids[call_id] = true
                        local result = client.exec_server_tool(self:get_format(), func, args)
                        local output = jsonc.stringify(result, false)
                        table.insert(function_call.tool_outputs, {
                            tool_call_id = call_id,
                            output = output,
                            name = func
                        })
                        table.insert(speaker.tool_calls, {
                            id = call_id,
                            type = "function",
                            ["function"] = {
                                name = func,
                                arguments = jsonc.stringify(args or {}, false)
                            }
                        })
                        if first_output_str == "" then first_output_str = output end
                    end
                else
                    local result = client.exec_server_tool(self:get_format(), func, args)
                    local output = jsonc.stringify(result, false)
                    table.insert(function_call.tool_outputs, { output = output, name = func })
                    table.insert(speaker.tool_calls, {
                        id = "",
                        type = "function",
                        ["function"] = { name = func, arguments = jsonc.stringify(args or {}, false) }
                    })
                    if first_output_str == "" then first_output_str = output end
                end
            end
        end
    end

    local plain_text_for_console = first_output_str
    function_call.reboot = reboot
    function_call.shutdown = shutdown
    local response_ai_json = jsonc.stringify(function_call, false)
    if self then self.chunk_all = "" end
    return plain_text_for_console, response_ai_json, speaker, true
end

-- Inject tool definitions into the Anthropic request (beta tools schema)
function M.inject_schema(self, body)
    local is_use_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
    if not is_use_tool then
        return body
    end
    if self and self.get_format and (self:get_format() == common.ai.format.title) then
        return body
    end

    local client = require("oasis.local.tool.client")
    local schema = client.get_function_call_schema()

    body.tools = body.tools or {}
    for _, tool_def in ipairs(schema or {}) do
        local params = tool_def.parameters or {}
        table.insert(body.tools, {
            type = "custom",
            name = tool_def.name,
            description = tool_def.description or "",
            input_schema = {
                type = params.type or "object",
                properties = params.properties or {},
                required = params.required or {}
            }
        })
    end

    -- Add tool_choice only when tools exist; otherwise remove both
    if body.tools and (#body.tools > 0) then
        body.tool_choice = { type = "auto" }
    else
        body.tools = nil
        body.tool_choice = nil
    end
    return body
end

-- Convert tool result message (role=tool) for Anthropic follow-up turn
function M.convert_tool_result(chat, speaker, msg)
    if (not speaker) or (speaker.role ~= "tool") then
        return nil
    end

    msg.name = speaker.name
    msg.content = speaker.content or speaker.message or ""
    msg.tool_call_id = speaker.tool_call_id

    table.insert(chat.messages, msg)
    return true
end

-- Convert assistant message that contains tool_calls (OpenAI style) to unified
function M.convert_tool_call(chat, speaker, msg)
    if (not speaker) or (speaker.role ~= common.role.assistant) or (not speaker.tool_calls) then
        return nil
    end

    local fixed_tool_calls = {}
    for _, tc in ipairs(speaker.tool_calls or {}) do
        local fn = tc["function"] or {}
        fn.arguments = ous.normalize_arguments(fn.arguments)
        fn.arguments = jsonc.stringify(fn.arguments, false)
        table.insert(fixed_tool_calls, {
            id = tc.id,
            type = "function",
            ["function"] = fn
        })
    end
    msg.tool_calls = fixed_tool_calls
    msg.content = speaker.content or ""
    table.insert(chat.messages, msg)
    return true
end

return M

