#!/usr/bin/env lua

local jsonc      = require("luci.jsonc")
local common     = require("oasis.common")
local uci        = require("luci.model.uci").cursor()
local debug      = require("oasis.chat.debug")
local ous        = require("oasis.unified.chat.schema")
local chat_error = require("oasis.chat.error")

local M = {}

local function stringify_object(value)
    local encoded = jsonc.stringify(value, false)
    if type(encoded) ~= "string" or encoded:match("^%s*%[%s*%]%s*$") then
        return "{}"
    end
    return encoded
end

local function tools_enabled(self)
    return uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
        and common.check_function_calling_enabled(self)
end

local function parse_arguments(self, call)
    local raw = tostring(call.arguments or "")
    local trimmed = raw:match("^%s*(.-)%s*$") or ""
    if trimmed:sub(1, 1) ~= "{" or trimmed:sub(-1) ~= "}" then
        return nil, chat_error.build(self, {
            phase = "function_calling",
            kind = "parse_error",
            message = "OpenAI returned invalid Function Calling arguments.",
            detail = "call_id=" .. tostring(call.call_id or call.id or ""),
            can_continue = false,
        })
    end

    local ok, parsed = pcall(jsonc.parse, trimmed)
    if (not ok) or type(parsed) ~= "table" or #parsed > 0 then
        return nil, chat_error.build(self, {
            phase = "function_calling",
            kind = "parse_error",
            message = "OpenAI returned invalid Function Calling arguments.",
            detail = "call_id=" .. tostring(call.call_id or call.id or ""),
            can_continue = false,
        })
    end

    return parsed, nil
end

function M.inject_schema(self, body, disable_tools)
    body.tools = nil
    body.tool_choice = nil
    self._request_tools_enabled = false
    self._request_tool_names = {}

    if disable_tools or (self.get_format and self:get_format() == common.ai.format.title)
        or not tools_enabled(self) then
        return body
    end

    local client = require("oasis.local.tool.client")
    local schema = client.get_function_call_schema() or {}
    local tools = {}

    for _, tool_def in ipairs(schema) do
        local name = tostring(tool_def.name or "")
        tools[#tools + 1] = {
            type = "function",
            name = name,
            description = tostring(tool_def.description or ""),
            parameters = tool_def.parameters or {},
            -- Existing Oasis tool schemas do not guarantee OpenAI strict-mode
            -- requirements (all properties required and additionalProperties=false).
            strict = false,
        }
        self._request_tool_names[name] = true
    end

    if #tools > 0 then
        body.tools = tools
        body.tool_choice = "auto"
        self._request_tools_enabled = true
    end

    return body
end

function M.process(self, calls)
    if not self._request_tools_enabled or not tools_enabled(self) then
        return nil, nil, nil, false, chat_error.build(self, {
            phase = "function_calling",
            kind = "unsupported_feature",
            message = "OpenAI requested a tool when Function Calling was disabled.",
        })
    end

    local client = require("oasis.local.tool.client")
    local function_call = { service = "OpenAI", tool_outputs = {} }
    local speaker = { role = common.role.assistant, content = "", tool_calls = {} }
    local first_output = ""
    local reboot = false
    local shutdown = false
    local prepared = {}
    local batch_ids = {}

    self.processed_tool_call_ids = self.processed_tool_call_ids or {}
    self._processed_tool_results = self._processed_tool_results or {}

    -- Validate the complete batch before executing any local tool. Otherwise a
    -- malformed later call could leave an earlier external side effect committed.
    for _, call in ipairs(calls or {}) do
        local call_id = tostring(call.call_id or "")
        local name = tostring(call.name or "")
        if #call_id == 0 or #name == 0 then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling",
                kind = "parse_error",
                message = "OpenAI returned an incomplete function call.",
                detail = "call_id=" .. call_id .. " name=" .. name,
                can_continue = false,
            })
        end
        if type(self._request_tool_names) ~= "table"
            or self._request_tool_names[name] ~= true then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling",
                kind = "unsupported_feature",
                message = "OpenAI requested a function that was not offered.",
                detail = "call_id=" .. call_id .. " name=" .. name,
                can_continue = false,
            })
        end

        local args, args_err = parse_arguments(self, call)
        if args_err then
            return nil, nil, nil, false, args_err
        end

        local normalized_args = stringify_object(args)
        local signature = name .. "\0" .. normalized_args
        local previous_signature = self.processed_tool_call_ids[call_id]
        local cached = self._processed_tool_results[call_id]
        if batch_ids[call_id] then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling",
                kind = "parse_error",
                message = "OpenAI returned a duplicate Function Calling ID.",
                detail = "call_id=" .. call_id,
                can_continue = false,
            })
        end
        batch_ids[call_id] = true

        if previous_signature
            and (previous_signature ~= signature or type(cached) ~= "table") then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling",
                kind = "parse_error",
                message = "OpenAI reused a Function Calling ID with different data.",
                detail = "call_id=" .. call_id,
                can_continue = false,
            })
        end

        prepared[#prepared + 1] = {
            call_id = call_id,
            name = name,
            args = args,
            normalized_args = normalized_args,
            signature = signature,
            cached = previous_signature and cached or nil,
        }
    end

    for _, call in ipairs(prepared) do
        local output
        if call.cached then
            output = call.cached.output
            reboot = reboot or call.cached.reboot == true
            shutdown = shutdown or call.cached.shutdown == true
            debug:log("oasis.log", "openai_responses.process",
                "reuse cached tool result call_id=" .. call.call_id)
        else
            local result = client.exec_server_tool(self:get_format(), call.name, call.args)
            output = jsonc.stringify(result, false)
            if type(output) ~= "string" then
                output = "null"
            end

            local result_reboot = type(result) == "table" and result.reboot == true
            local result_shutdown = type(result) == "table" and result.shutdown == true
            reboot = reboot or result_reboot
            shutdown = shutdown or result_shutdown
            self.processed_tool_call_ids[call.call_id] = call.signature
            self._processed_tool_results[call.call_id] = {
                output = output,
                reboot = result_reboot,
                shutdown = result_shutdown,
            }
            self._tool_side_effects_committed = true
            debug:log("oasis.log", "openai_responses.process",
                "executed tool call_id=" .. call.call_id .. " name=" .. call.name)
        end

        function_call.tool_outputs[#function_call.tool_outputs + 1] = {
            tool_call_id = call.call_id,
            output = output,
            name = call.name,
        }
        speaker.tool_calls[#speaker.tool_calls + 1] = {
            id = call.call_id,
            type = "function",
            ["function"] = {
                name = call.name,
                arguments = call.normalized_args,
            },
        }
        if #first_output == 0 then
            first_output = output
        end
    end

    function_call.reboot = reboot
    function_call.shutdown = shutdown
    return first_output, jsonc.stringify(function_call, false), speaker, true, nil
end

function M.convert_tool_result(chat, speaker, msg)
    if not speaker.content or #tostring(speaker.content) == 0 then
        return false
    end
    msg.name = speaker.name or speaker.tool_name
    msg.tool_name = speaker.tool_name or speaker.name
    msg.tool_call_id = speaker.tool_call_id
    msg.content = speaker.content
    table.insert(chat.messages, msg)
    return true
end

function M.convert_tool_call(chat, speaker, msg)
    local fixed = {}
    for _, call in ipairs(speaker.tool_calls or {}) do
        local fn = call["function"] or {}
        local args = ous.normalize_arguments(fn.arguments)
        fixed[#fixed + 1] = {
            id = call.id,
            type = "function",
            ["function"] = {
                name = fn.name,
                arguments = stringify_object(args),
            },
        }
    end
    msg.content = speaker.content or ""
    msg.tool_calls = fixed
    table.insert(chat.messages, msg)
    return true
end

return M
