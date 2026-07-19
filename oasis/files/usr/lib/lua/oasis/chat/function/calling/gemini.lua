#!/usr/bin/env lua

local jsonc      = require("luci.jsonc")
local common     = require("oasis.common")
local uci        = require("luci.model.uci").cursor()
local debug      = require("oasis.chat.debug")
local ous        = require("oasis.unified.chat.schema")
local chat_error = require("oasis.chat.error")

local M = {}

-- This is a local safety bound. Gemini can return parallel Function Calls, but
-- an unbounded batch must not turn one model response into unbounded local work.
local MAX_TOOL_CALLS_PER_BATCH = 64
local MAX_TOOL_OUTPUT_BYTES = 4 * 1024 * 1024
local MAX_TOOL_BATCH_OUTPUT_BYTES = 6 * 1024 * 1024

local function copy_value(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[copy_value(key, seen)] = copy_value(item, seen)
    end
    return result
end

local function dense_array_length(value)
    if type(value) ~= "table" then
        return nil
    end

    local count = 0
    local maximum = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return nil
        end
        count = count + 1
        if key > maximum then
            maximum = key
        end
    end

    if maximum ~= count then
        return nil
    end
    return count
end

local function is_json_object(value)
    if type(value) ~= "table" then
        return false
    end
    for key in pairs(value) do
        if type(key) ~= "string" then
            return false
        end
    end
    return true
end

-- Return a stable JSON representation so that a retry with reordered object
-- keys is still recognized as the same call. The original Lua value is passed
-- to the tool; this serializer is used for identity and saved tool-call data.
local function canonical_json(value, stack)
    local value_type = type(value)
    if value_type ~= "table" then
        if value_type == "number"
            and (value ~= value or value == math.huge or value == -math.huge) then
            return nil, "non-finite number"
        end

        local ok, encoded = pcall(jsonc.stringify, value, false)
        if not ok or type(encoded) ~= "string" then
            return nil, "unsupported JSON value"
        end
        return encoded
    end

    stack = stack or {}
    if stack[value] then
        return nil, "cyclic table"
    end
    stack[value] = true

    local array_length = dense_array_length(value)
    if array_length ~= nil and array_length > 0 then
        local items = {}
        for index = 1, array_length do
            local encoded, err = canonical_json(value[index], stack)
            if not encoded then
                stack[value] = nil
                return nil, err
            end
            items[#items + 1] = encoded
        end
        stack[value] = nil
        return "[" .. table.concat(items, ",") .. "]"
    end

    if not is_json_object(value) then
        stack[value] = nil
        return nil, "mixed or sparse JSON table"
    end

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    local fields = {}
    for _, key in ipairs(keys) do
        local ok, encoded_key = pcall(jsonc.stringify, key, false)
        local encoded_value, err = canonical_json(value[key], stack)
        if not ok or type(encoded_key) ~= "string" or not encoded_value then
            stack[value] = nil
            return nil, err or "invalid JSON object key"
        end
        fields[#fields + 1] = encoded_key .. ":" .. encoded_value
    end
    stack[value] = nil
    return "{" .. table.concat(fields, ",") .. "}"
end

local function stringify_object(value)
    if not is_json_object(value) then
        return nil
    end
    return canonical_json(value)
end

local function tools_enabled(self)
    return type(self) == "table"
        and uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
        and common.check_function_calling_enabled(self)
end

local function build_error(self, kind, message, detail)
    return chat_error.build(self, {
        phase = "function_calling",
        kind = kind,
        message = message,
        detail = detail,
        can_continue = false,
    })
end

local function build_tool_error(self, message, detail)
    return chat_error.build(self, {
        phase = "tool_execution",
        kind = "tool_error",
        message = message,
        detail = detail,
        can_continue = false,
    })
end

local function detect_function_call_in_parts(parts)
    if type(parts) ~= "table" then
        return false
    end
    for _, part in ipairs(parts) do
        if type(part) == "table" and type(part.functionCall) == "table" then
            return true
        end
    end
    return false
end

function M.detect(message)
    if type(message) ~= "table" then
        return false
    end

    -- Retain detection compatibility for older callers. New Gemini service
    -- code normalizes these blocks before passing them to process().
    if type(message.tool_calls) == "table" and #message.tool_calls > 0 then
        local tool = message.tool_calls[1]
        if type(tool) == "table" and type(tool["function"]) == "table"
            and tool["function"].name and tool["function"].arguments then
            return true
        end
    end

    if type(message.candidates) == "table" then
        local candidate = message.candidates[1]
        local parts = candidate and candidate.content and candidate.content.parts
        return detect_function_call_in_parts(parts)
    end
    if message.parts then
        return detect_function_call_in_parts(message.parts)
    end
    return type(message.functionCall) == "table"
end

local function validate_parameters(parameters)
    if not is_json_object(parameters) then
        return nil, "parameters must be a JSON object"
    end

    local copied = copy_value(parameters)
    copied.type = copied.type or "object"
    if copied.type ~= "object" then
        return nil, "parameters.type must be object"
    end

    if copied.properties == nil then
        copied.properties = {}
    elseif not is_json_object(copied.properties) then
        return nil, "parameters.properties must be a JSON object"
    end

    if copied.required ~= nil then
        local required_count = dense_array_length(copied.required)
        if required_count == nil then
            return nil, "parameters.required must be an array"
        end
        local required_names = {}
        for index = 1, required_count do
            local name = copied.required[index]
            if type(name) ~= "string" or #name == 0 or required_names[name] then
                return nil, "parameters.required must contain unique names"
            end
            if copied.properties[name] == nil then
                return nil, "parameters.required names must exist in properties"
            end
            required_names[name] = true
        end
    end

    local encoded, err = canonical_json(copied)
    if not encoded then
        return nil, err
    end
    return copied
end

-- Add user-defined tools to a native Gemini GenerateContent request. Tool
-- result continuations reuse the exact declaration snapshot from request one.
function M.inject_schema(self, body, opts)
    if type(self) ~= "table" then
        error("Gemini Function Calling requires a service instance.")
    end

    body = body or {}
    if type(body) ~= "table" then
        error("Gemini request body must be a table.")
    end
    opts = opts or {}
    body.tools = nil
    body.toolConfig = nil
    self._request_tools_enabled = false
    self._request_tool_names = {}
    self._request_tool_choice = nil

    local followup = opts.followup == true
    if self.get_format and self:get_format() == common.ai.format.title then
        if not followup then
            self._active_tool_definitions = nil
        end
        return body
    end

    local definitions
    if followup and type(self._active_tool_definitions) == "table"
        and #self._active_tool_definitions > 0 then
        definitions = copy_value(self._active_tool_definitions)
    elseif not followup and tools_enabled(self) then
        local client = require("oasis.local.tool.client")
        local schema = client.get_function_call_schema() or {}
        local schema_count = dense_array_length(schema)
        if schema_count == nil then
            error("Gemini tool schema must be a dense array.")
        end

        definitions = {}
        local definition_names = {}
        for index = 1, schema_count do
            local tool_def = schema[index]
            if type(tool_def) ~= "table" then
                error("Gemini tool schema entry must be a table.")
            end

            local name = tostring(tool_def.name or "")
            if #name == 0 or definition_names[name] then
                error("Gemini tool names must be non-empty and unique.")
            end
            if #name > 128 or not name:match("^[A-Za-z0-9_.:%-]+$") then
                error("Gemini tool names contain unsupported characters or exceed 128 bytes.")
            end
            definition_names[name] = true

            local raw_parameters = tool_def.parameters
            if raw_parameters == nil then
                raw_parameters = {}
            end
            local parameters, parameters_err =
                validate_parameters(raw_parameters)
            if not parameters then
                error("Invalid Gemini parameters for " .. name .. ": "
                    .. tostring(parameters_err))
            end

            definitions[#definitions + 1] = {
                name = name,
                description = tostring(tool_def.description or ""),
                parameters = parameters,
            }
        end
        self._active_tool_definitions = copy_value(definitions)
    end

    if followup and (type(definitions) ~= "table" or #definitions == 0) then
        error("Gemini Tool continuation lost its active tool definitions.")
    end
    if type(definitions) ~= "table" or #definitions == 0 then
        if not followup then
            self._active_tool_definitions = nil
        end
        return body
    end

    for _, definition in ipairs(definitions) do
        self._request_tool_names[definition.name] = true
    end

    local mode = opts.force_none and "NONE" or "AUTO"
    body.tools = {
        {
            functionDeclarations = copy_value(definitions),
        },
    }
    body.toolConfig = {
        functionCallingConfig = {
            mode = mode,
        },
    }
    self._request_tools_enabled = true
    self._request_tool_choice = mode
    return body
end

-- Validate the complete batch before executing any local tool. A malformed
-- later call must never leave an earlier external side effect committed.
function M.process(self, calls)
    if type(self) ~= "table" or not self._request_tools_enabled
        or not tools_enabled(self) then
        return nil, nil, nil, false, build_error(self, "unsupported_feature",
            "Gemini requested a tool when Function Calling was disabled.")
    end
    if self._request_tool_choice == "NONE" then
        return nil, nil, nil, false, build_error(self, "unsupported_feature",
            "Gemini requested another tool after Function Calling was closed for this turn.")
    end

    local call_count = dense_array_length(calls)
    if call_count == nil then
        return nil, nil, nil, false, build_error(self, "parse_error",
            "Gemini returned a sparse or invalid Function Calling batch.")
    end
    if call_count == 0 then
        return nil, nil, nil, false, build_error(self, "parse_error",
            "Gemini reported Function Calling without any calls.")
    end
    if call_count > MAX_TOOL_CALLS_PER_BATCH then
        return nil, nil, nil, false, build_error(self, "parse_error",
            "Gemini returned too many Function Calls.",
            "count=" .. tostring(call_count)
                .. " limit=" .. tostring(MAX_TOOL_CALLS_PER_BATCH))
    end

    local prepared = {}
    local batch_ids = {}
    local batch_provider_ids = {}
    self.processed_tool_call_ids = self.processed_tool_call_ids or {}
    self._processed_tool_results = self._processed_tool_results or {}

    for index = 1, call_count do
        local call = calls[index]
        if type(call) ~= "table" then
            return nil, nil, nil, false, build_error(self, "parse_error",
                "Gemini returned an invalid Function Call.",
                "index=" .. tostring(index))
        end

        local call_id = tostring(call.id or "")
        local provider_id = call.provider_id
        if provider_id ~= nil then
            provider_id = tostring(provider_id)
        end
        local name = tostring(call.name or "")

        if #call_id == 0 or #name == 0 then
            return nil, nil, nil, false, build_error(self, "parse_error",
                "Gemini returned an incomplete Function Call.",
                "index=" .. tostring(index))
        end
        if batch_ids[call_id] then
            return nil, nil, nil, false, build_error(self, "parse_error",
                "Gemini returned a duplicate internal Function Call ID.",
                "call_id=" .. call_id)
        end
        batch_ids[call_id] = true

        -- Gemini FunctionCall.id is optional. Only a non-empty provider ID is
        -- subject to uniqueness validation.
        if provider_id and #provider_id > 0 then
            if batch_provider_ids[provider_id] then
                return nil, nil, nil, false, build_error(self, "parse_error",
                    "Gemini returned a duplicate Function Call ID.",
                    "provider_id=" .. provider_id)
            end
            batch_provider_ids[provider_id] = true
        end

        if type(self._request_tool_names) ~= "table"
            or self._request_tool_names[name] ~= true then
            return nil, nil, nil, false, build_error(self, "unsupported_feature",
                "Gemini requested a function that was not offered.",
                "call_id=" .. call_id .. " name=" .. name)
        end

        local args = call.args
        if args == nil then
            args = {}
        end
        if not is_json_object(args) then
            return nil, nil, nil, false, build_error(self, "parse_error",
                "Gemini returned non-object Function Call arguments.",
                "call_id=" .. call_id)
        end
        local normalized_args, args_err = stringify_object(args)
        if not normalized_args then
            return nil, nil, nil, false, build_error(self, "parse_error",
                "Gemini returned invalid Function Call arguments.",
                "call_id=" .. call_id .. " reason=" .. tostring(args_err))
        end

        local provider_part_json = call.provider_part_json
        if provider_part_json ~= nil
            and (type(provider_part_json) ~= "string"
                or #provider_part_json == 0) then
            return nil, nil, nil, false, build_error(self, "parse_error",
                "Gemini returned invalid raw Function Call data.",
                "call_id=" .. call_id)
        end
        local signature_source = {
            provider_id = provider_id or "",
            name = name,
            args = args,
        }
        if provider_part_json ~= nil then
            signature_source.provider_part_json = provider_part_json
        end
        local signature, signature_err =
            canonical_json(signature_source)
        if not signature then
            return nil, nil, nil, false, build_error(self, "parse_error",
                "Gemini returned invalid Function Call data.",
                "call_id=" .. call_id .. " reason=" .. tostring(signature_err))
        end

        local previous_signature = self.processed_tool_call_ids[call_id]
        local cached = self._processed_tool_results[call_id]
        if (previous_signature == nil) ~= (cached == nil)
            or (previous_signature ~= nil
                and (previous_signature ~= signature
                    or type(cached) ~= "table"
                    or type(cached.output) ~= "string")) then
            return nil, nil, nil, false, build_error(self, "parse_error",
                "Gemini reused a Function Call ID with different data.",
                "call_id=" .. call_id)
        end

        prepared[#prepared + 1] = {
            id = call_id,
            provider_id = provider_id,
            name = name,
            args = args,
            normalized_args = normalized_args,
            signature = signature,
            cached = previous_signature and cached or nil,
        }
    end

    local client = require("oasis.local.tool.client")
    local function_call = { service = "Gemini", tool_outputs = {} }
    local speaker = {
        role = common.role.assistant,
        content = "",
        tool_calls = {},
    }
    local first_output = ""
    local reboot = false
    local shutdown = false
    local cached_count = 0
    local output_bytes = 0

    for _, call in ipairs(prepared) do
        local output
        if call.cached then
            output = call.cached.output
            reboot = reboot or call.cached.reboot == true
            shutdown = shutdown or call.cached.shutdown == true
            cached_count = cached_count + 1
        else
            -- Local tools can commit an external side effect before returning
            -- or raising, so retries become unsafe immediately before exec.
            self._tool_side_effects_committed = true
            local result = client.exec_server_tool(
                self:get_format(), call.name, call.args)
            local ok, encoded = pcall(jsonc.stringify, result, false)
            output = (ok and type(encoded) == "string") and encoded or "null"

            local result_reboot =
                type(result) == "table" and result.reboot == true
            local result_shutdown =
                type(result) == "table" and result.shutdown == true
            reboot = reboot or result_reboot
            shutdown = shutdown or result_shutdown
            self.processed_tool_call_ids[call.id] = call.signature
            self._processed_tool_results[call.id] = {
                output = output,
                reboot = result_reboot,
                shutdown = result_shutdown,
            }
        end
        if #output > MAX_TOOL_OUTPUT_BYTES then
            return nil, nil, nil, false, build_tool_error(
                self,
                "A Gemini Tool result exceeded the output size limit.",
                "limit=" .. tostring(MAX_TOOL_OUTPUT_BYTES))
        end
        if #output > MAX_TOOL_BATCH_OUTPUT_BYTES - output_bytes then
            return nil, nil, nil, false, build_tool_error(
                self,
                "Gemini Tool results exceeded the batch output size limit.",
                "limit=" .. tostring(MAX_TOOL_BATCH_OUTPUT_BYTES))
        end
        output_bytes = output_bytes + #output

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
    debug:log("oasis.log", "gemini.process",
        string.format("processed Function Calls: count=%d cached=%d",
            #prepared, cached_count))
    return first_output, jsonc.stringify(function_call, false),
        speaker, true, nil
end

-----------------------------------
-- Convert Function Calling Data --
-----------------------------------
function M.convert_tool_result(chat, speaker, msg)
    if type(chat) ~= "table" or type(chat.messages) ~= "table"
        or type(speaker) ~= "table" or type(msg) ~= "table" then
        return false
    end

    local content = speaker.content
    if content == nil or #tostring(content) == 0 then
        return false
    end

    local name = tostring(speaker.name or speaker.tool_name or "")
    local call_id = tostring(speaker.tool_call_id or "")
    if #name == 0 or #call_id == 0 then
        return false
    end

    msg.name = name
    msg.content = content
    msg.tool_call_id = call_id
    table.insert(chat.messages, msg)
    return true
end

function M.convert_tool_call(chat, speaker, msg)
    if type(chat) ~= "table" or type(chat.messages) ~= "table"
        or type(speaker) ~= "table" or type(msg) ~= "table"
        or type(speaker.tool_calls) ~= "table" then
        return false
    end

    local count = dense_array_length(speaker.tool_calls)
    if count == nil or count == 0 then
        return false
    end

    local fixed_tool_calls = {}
    for index = 1, count do
        local tool_call = speaker.tool_calls[index]
        local fn = type(tool_call) == "table" and tool_call["function"] or nil
        local call_id = type(tool_call) == "table"
            and tostring(tool_call.id or "") or ""
        local name = type(fn) == "table" and tostring(fn.name or "") or ""
        if #call_id == 0 or #name == 0 then
            return false
        end

        local args = ous.normalize_arguments(fn.arguments)
        local normalized_args = stringify_object(args)
        if not normalized_args then
            return false
        end

        fixed_tool_calls[#fixed_tool_calls + 1] = {
            id = call_id,
            type = "function",
            ["function"] = {
                name = name,
                arguments = normalized_args,
            },
        }
    end

    msg.tool_calls = fixed_tool_calls
    msg.content = speaker.content or ""
    table.insert(chat.messages, msg)
    return true
end

return M
