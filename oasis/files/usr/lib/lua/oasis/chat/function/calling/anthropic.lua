#!/usr/bin/env lua

local jsonc      = require("luci.jsonc")
local common     = require("oasis.common")
local uci        = require("luci.model.uci").cursor()
local debug      = require("oasis.chat.debug")
local ous        = require("oasis.unified.chat.schema")
local chat_error = require("oasis.chat.error")

local M = {}

local function copy_value(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}
    for key, item in pairs(value) do
        result[copy_value(key)] = copy_value(item)
    end
    return result
end

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

local function parse_input(self, call)
    local input = call.input
    local raw = call.input_json

    if raw ~= nil and #tostring(raw) > 0 then
        local trimmed = tostring(raw):match("^%s*(.-)%s*$") or ""
        if trimmed:sub(1, 1) ~= "{" or trimmed:sub(-1) ~= "}" then
            return nil, chat_error.build(self, {
                phase = "function_calling",
                kind = "parse_error",
                message = "Anthropic returned invalid Tool Use input.",
                detail = "tool_use_id=" .. tostring(call.id or ""),
                can_continue = false,
            })
        end

        local ok, parsed = pcall(jsonc.parse, trimmed)
        if (not ok) or type(parsed) ~= "table" or #parsed > 0 then
            return nil, chat_error.build(self, {
                phase = "function_calling",
                kind = "parse_error",
                message = "Anthropic returned invalid Tool Use input.",
                detail = "tool_use_id=" .. tostring(call.id or ""),
                can_continue = false,
            })
        end
        input = parsed
    end

    if type(input) ~= "table" or #input > 0 then
        return nil, chat_error.build(self, {
            phase = "function_calling",
            kind = "parse_error",
            message = "Anthropic returned non-object Tool Use input.",
            detail = "tool_use_id=" .. tostring(call.id or ""),
            can_continue = false,
        })
    end

    return input, nil
end

-- Add user-defined tools to an Anthropic request. During a tool-result
-- continuation the exact same definitions are reused from the first request.
function M.inject_schema(self, body, opts)
    opts = opts or {}
    body.tools = nil
    body.tool_choice = nil
    self._request_tools_enabled = false
    self._request_tool_names = {}
    self._request_tool_choice = nil

    if self.get_format and self:get_format() == common.ai.format.title then
        return body
    end

    local followup = opts.followup == true
    local definitions
    if followup and type(self._active_tool_definitions) == "table"
        and #self._active_tool_definitions > 0 then
        definitions = copy_value(self._active_tool_definitions)
    elseif tools_enabled(self) then
        local client = require("oasis.local.tool.client")
        definitions = {}
        local definition_names = {}
        for _, tool_def in ipairs(client.get_function_call_schema() or {}) do
            if type(tool_def) ~= "table" then
                error("Anthropic tool schema entry must be a table.")
            end
            local name = tostring(tool_def.name or "")
            if #name == 0 or definition_names[name] then
                error("Anthropic tool names must be non-empty and unique.")
            end
            definition_names[name] = true

            local params = tool_def.parameters or {}
            if type(params) ~= "table" or #params > 0 then
                error("Anthropic tool input_schema must be a JSON object schema.")
            end
            local input_schema = copy_value(params)
            input_schema.type = input_schema.type or "object"
            input_schema.properties = input_schema.properties or {}
            input_schema.required = input_schema.required or {}
            if input_schema.type ~= "object"
                or type(input_schema.properties) ~= "table"
                or #input_schema.properties > 0
                or type(input_schema.required) ~= "table" then
                error("Anthropic tool input_schema must describe an object.")
            end
            definitions[#definitions + 1] = {
                name = name,
                description = tostring(tool_def.description or ""),
                input_schema = input_schema,
            }
        end
        self._active_tool_definitions = copy_value(definitions)
    end

    if type(definitions) ~= "table" or #definitions == 0 then
        if not followup then
            self._active_tool_definitions = nil
        end
        return body
    end

    for _, tool_def in ipairs(definitions) do
        local name = tostring(tool_def.name or "")
        if #name > 0 then
            self._request_tool_names[name] = true
        end
    end

    body.tools = definitions
    self._request_tool_choice = opts.force_none and "none" or "auto"
    body.tool_choice = { type = self._request_tool_choice }
    self._request_tools_enabled = true
    return body
end

-- Validate the complete batch before executing any tool. This prevents a
-- malformed later call from leaving an earlier external side effect committed.
function M.process(self, calls)
    if not self._request_tools_enabled or not tools_enabled(self) then
        return nil, nil, nil, false, chat_error.build(self, {
            phase = "function_calling",
            kind = "unsupported_feature",
            message = "Anthropic requested a tool when Function Calling was disabled.",
            can_continue = false,
        })
    end
    if self._request_tool_choice == "none" then
        return nil, nil, nil, false, chat_error.build(self, {
            phase = "function_calling",
            kind = "unsupported_feature",
            message = "Anthropic requested another tool after Tool Use was closed for this turn.",
            can_continue = false,
        })
    end

    local prepared = {}
    local batch_ids = {}
    self.processed_tool_call_ids = self.processed_tool_call_ids or {}
    self._processed_tool_results = self._processed_tool_results or {}

    for _, call in ipairs(calls or {}) do
        local call_id = tostring(call.id or call.tool_call_id or "")
        local name = tostring(call.name or "")
        if #call_id == 0 or #name == 0 then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling",
                kind = "parse_error",
                message = "Anthropic returned an incomplete Tool Use block.",
                detail = "tool_use_id=" .. call_id .. " name=" .. name,
                can_continue = false,
            })
        end
        if batch_ids[call_id] then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling",
                kind = "parse_error",
                message = "Anthropic returned a duplicate Tool Use ID.",
                detail = "tool_use_id=" .. call_id,
                can_continue = false,
            })
        end
        batch_ids[call_id] = true

        if type(self._request_tool_names) ~= "table"
            or self._request_tool_names[name] ~= true then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling",
                kind = "unsupported_feature",
                message = "Anthropic requested a tool that was not offered.",
                detail = "tool_use_id=" .. call_id .. " name=" .. name,
                can_continue = false,
            })
        end

        local args, input_error = parse_input(self, call)
        if input_error then
            return nil, nil, nil, false, input_error
        end
        local normalized_args = stringify_object(args)
        local signature = name .. "\0" .. normalized_args
        local previous_signature = self.processed_tool_call_ids[call_id]
        local cached = self._processed_tool_results[call_id]
        if previous_signature
            and (previous_signature ~= signature or type(cached) ~= "table") then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling",
                kind = "parse_error",
                message = "Anthropic reused a Tool Use ID with different data.",
                detail = "tool_use_id=" .. call_id,
                can_continue = false,
            })
        end

        prepared[#prepared + 1] = {
            id = call_id,
            name = name,
            args = args,
            normalized_args = normalized_args,
            signature = signature,
            cached = previous_signature and cached or nil,
        }
    end

    if #prepared == 0 then
        return nil, nil, nil, false, chat_error.build(self, {
            phase = "function_calling",
            kind = "parse_error",
            message = "Anthropic reported Tool Use without any tool calls.",
            can_continue = false,
        })
    end

    local client = require("oasis.local.tool.client")
    local function_call = { service = "Anthropic", tool_outputs = {} }
    local speaker = { role = common.role.assistant, content = "", tool_calls = {} }
    local first_output = ""
    local reboot = false
    local shutdown = false

    for _, call in ipairs(prepared) do
        local output
        if call.cached then
            output = call.cached.output
            reboot = reboot or call.cached.reboot == true
            shutdown = shutdown or call.cached.shutdown == true
            debug:log("oasis.log", "anthropic.process",
                "reuse cached tool result tool_use_id=" .. call.id)
        else
            -- The tool may perform an external side effect before raising an
            -- error, so retries become unsafe as soon as execution begins.
            self._tool_side_effects_committed = true
            local result = client.exec_server_tool(self:get_format(), call.name, call.args)
            output = jsonc.stringify(result, false)
            if type(output) ~= "string" then
                output = "null"
            end

            local result_reboot = type(result) == "table" and result.reboot == true
            local result_shutdown = type(result) == "table" and result.shutdown == true
            reboot = reboot or result_reboot
            shutdown = shutdown or result_shutdown
            self.processed_tool_call_ids[call.id] = call.signature
            self._processed_tool_results[call.id] = {
                output = output,
                reboot = result_reboot,
                shutdown = result_shutdown,
            }
            debug:log("oasis.log", "anthropic.process",
                "executed tool_use_id=" .. call.id .. " name=" .. call.name)
        end

        function_call.tool_outputs[#function_call.tool_outputs + 1] = {
            tool_call_id = call.id,
            output = output,
            name = call.name,
        }
        speaker.tool_calls[#speaker.tool_calls + 1] = {
            id = call.id,
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
    if not speaker or speaker.role ~= "tool" then
        return nil
    end
    msg.name = speaker.name
    msg.content = speaker.content or speaker.message or ""
    msg.tool_call_id = speaker.tool_call_id
    table.insert(chat.messages, msg)
    return true
end

function M.convert_tool_call(chat, speaker, msg)
    if not speaker or speaker.role ~= common.role.assistant
        or type(speaker.tool_calls) ~= "table" then
        return nil
    end

    local fixed = {}
    for _, tool_call in ipairs(speaker.tool_calls) do
        local fn = tool_call["function"] or {}
        local args = ous.normalize_arguments(fn.arguments)
        fixed[#fixed + 1] = {
            id = tool_call.id,
            type = "function",
            ["function"] = {
                name = fn.name,
                arguments = stringify_object(args),
            },
        }
    end
    msg.tool_calls = fixed
    msg.content = speaker.content or ""
    table.insert(chat.messages, msg)
    return true
end

return M
