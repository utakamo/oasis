#!/usr/bin/env lua

-- Bounded orchestration for AI tool calls.
--
-- Ordinary chat turns may use one normal tool batch and then must produce a
-- final answer with tools disabled.  The Tool Search management tools are the
-- only tools which may keep the sequence open so that a newly-enabled tool can
-- be selected and used in the same user turn.

local jsonc      = require("luci.jsonc")
local chat_error = require("oasis.chat.error")
local transfer   = require("oasis.chat.transfer")
local tool_policy = require("oasis.chat.function.calling.policy")
local common     = require("oasis.common")

local M = {}

local HARD_MAX_AI_REQUESTS = 6
local HARD_MAX_TOOL_ROUNDS = 4
local HARD_MAX_TOOL_CALLS = 8
local REQUIRED_TOOL_SEARCH_ABI = 2

local MANAGER_TOOLS = {
    get_tool_list = true,
    set_tool_enabled = true,
    set_tool_disabled = true,
}

local function validate_tool_search_abi(manager_name)
    local ok, state = pcall(require, "oasis.local.tool.state")
    if not ok or type(state) ~= "table" then
        return nil, "oasis-mod-tool state module is unavailable"
    end
    if state.TOOL_SEARCH_ABI ~= REQUIRED_TOOL_SEARCH_ABI
        or type(state.list_effective) ~= "function"
        or type(state.set_auto_enabled) ~= "function"
        or type(state.is_control_tool) ~= "function" then
        return nil, "incompatible oasis-mod-tool Tool Search ABI"
    end

    local uci_ok, uci_module = pcall(require, "luci.model.uci")
    if not uci_ok or type(uci_module) ~= "table"
        or type(uci_module.cursor) ~= "function" then
        return nil, "oasis-mod-tool UCI registry is unavailable"
    end
    local cursor_ok, cursor = pcall(uci_module.cursor)
    if not cursor_ok or type(cursor) ~= "table" then
        return nil, "oasis-mod-tool UCI cursor is unavailable"
    end
    local list_ok, registry = pcall(state.list_effective, cursor)
    if not list_ok or type(registry) ~= "table"
        or registry.status ~= "OK"
        or tool_policy.dense_array_length(registry.tool) == nil then
        return nil, "oasis-mod-tool control registry could not be verified"
    end

    local matches = 0
    local valid_binding = false
    for _, entry in ipairs(registry.tool) do
        if type(entry) == "table" and entry.name == manager_name then
            matches = matches + 1
            local binding_ok, is_control = pcall(
                state.is_control_tool, entry.server, entry.name)
            valid_binding = binding_ok and is_control == true
                and entry.enabled == true
                and entry.conflicted == false
        end
    end
    if matches ~= 1 or not valid_binding then
        return nil, "Tool Search control name is not uniquely bound to oasis.tool.manager"
    end
    return true
end

local function has_exact_keys(value, expected)
    local count = 0
    for key in pairs(value or {}) do
        if expected[key] ~= true then
            return false
        end
        count = count + 1
    end
    local expected_count = 0
    for _ in pairs(expected) do
        expected_count = expected_count + 1
    end
    return count == expected_count
end

local function validate_manager_arguments(call)
    if call.name == "get_tool_list" then
        if not has_exact_keys(call.arguments, {}) then
            return nil, "get_tool_list arguments must be an empty object"
        end
        return true
    end

    local expected = { server = true, tool = true }
    if not has_exact_keys(call.arguments, expected) then
        return nil, call.name
            .. " arguments must contain exactly server and tool"
    end
    if type(call.arguments.server) ~= "string"
        or not call.arguments.server:match("%S") then
        return nil, call.name .. " server must be a non-empty string"
    end
    if type(call.arguments.tool) ~= "string"
        or not call.arguments.tool:match("%S") then
        return nil, call.name .. " tool must be a non-empty string"
    end
    return true
end

local function has_committed_tool_side_effects(service)
    if type(service) ~= "table"
        or type(service.get_tool_side_effects_committed) ~= "function" then
        return false
    end

    local ok, committed = pcall(function()
        return service:get_tool_side_effects_committed()
    end)
    return ok and committed == true
end

local function bounded_limit(value, default, hard_max)
    local number = tonumber(value)
    if not number then
        return default
    end
    number = math.floor(number)
    if number < 1 then
        return 1
    end
    if number > hard_max then
        return hard_max
    end
    return number
end

local function dense_array_length(value)
    if type(value) ~= "table" then
        return nil
    end
    local count = 0
    local maximum = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1
            or key ~= math.floor(key) then
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

local function build_error(service, message, detail, kind)
    return chat_error.build(service, {
        phase = "tool_execution",
        kind = kind or "tool_error",
        message = message,
        detail = detail,
        -- Pre-execution validation failures are safe to correct with another
        -- user message. Runner:_fail() closes retryability once authorization
        -- or provider-side execution has crossed the side-effect boundary.
        can_continue = true,
    })
end

local function decode_json(value)
    if type(value) ~= "string" or #value == 0 then
        return nil
    end
    local ok, decoded = pcall(jsonc.parse, value)
    if ok then
        return decoded
    end
    return nil
end

local function normalize_arguments(value)
    if value == nil or value == "" then
        return {}, false
    end
    if type(value) == "string" then
        local decoded = decode_json(value)
        if type(decoded) ~= "table" then
            return nil, false
        end
        value = decoded
    end
    if type(value) ~= "table" then
        return nil, false
    end
    for key in pairs(value) do
        if type(key) ~= "string" then
            return nil, false
        end
    end
    return value, true
end

local function normalize_call_descriptor(call)
    if type(call) ~= "table" then
        return nil, "tool call is not an object"
    end

    local fn = type(call["function"]) == "table" and call["function"] or nil
    local name = call.name or (fn and fn.name)
    if type(name) ~= "string" or not name:match("%S") then
        return nil, "tool name is missing"
    end

    local raw_arguments = call.arguments
    if raw_arguments == nil and call.args ~= nil then
        raw_arguments = call.args
    end
    if raw_arguments == nil and fn then
        raw_arguments = fn.arguments
    end

    local arguments, has_arguments = normalize_arguments(raw_arguments)
    if arguments == nil then
        return nil, "tool arguments are not a JSON object"
    end

    local signature
    if has_arguments then
        local canonical, canonical_error =
            tool_policy.canonical_object(arguments)
        if not canonical then
            return nil, "tool arguments are invalid JSON: "
                .. tostring(canonical_error)
        end
        signature = name .. "\0" .. canonical
    else
        -- Some legacy provider adapters do not expose arguments in tool_info.
        -- Include the call ID so distinct calls are not incorrectly classified
        -- as the same operation. Updated adapters should always include args.
        signature = name .. "\0<missing>\0"
            .. tostring(call.tool_call_id or call.id or "")
    end

    -- Management operations have strict object contracts checked during
    -- preflight. Give them canonical argument identity even when a provider
    -- omits the optional empty object for get_tool_list; post-execution
    -- tool_info must derive the same signature as authorization did.
    if MANAGER_TOOLS[name] then
        local canonical, canonical_error =
            tool_policy.canonical_object(arguments)
        if not canonical then
            return nil, "tool arguments are invalid JSON: "
                .. tostring(canonical_error)
        end
        signature = name .. "\0" .. canonical
    end

    local raw_id = call.tool_call_id
    if raw_id == nil then
        raw_id = call.id
    end

    return {
        id = raw_id == nil and nil or tostring(raw_id),
        name = name,
        arguments = arguments,
        signature = signature,
        manager = MANAGER_TOOLS[name] == true,
    }
end

local function nested_result(payload)
    if type(payload) ~= "table" then
        return nil
    end
    if type(payload.result) == "string" then
        local decoded = decode_json(payload.result)
        if type(decoded) == "table" then
            return decoded
        end
    elseif type(payload.result) == "table" then
        return payload.result
    end
    return nil
end

local function result_field(payload, key)
    if type(payload) ~= "table" then
        return nil
    end
    if payload[key] ~= nil then
        return payload[key]
    end
    local nested = nested_result(payload)
    return nested and nested[key] or nil
end

local function has_error_value(value)
    if value == nil or value == false then
        return false
    end
    return type(value) ~= "string" or value:match("%S") ~= nil
end

local function confirmation_from(parsed_info, calls)
    local confirmation = {
        reboot = parsed_info.reboot == true,
        shutdown = parsed_info.shutdown == true,
        prepare_service_restart = nil,
    }

    for _, call in ipairs(calls) do
        local payload = call.output
        if result_field(payload, "reboot") == true then
            confirmation.reboot = true
        end
        if result_field(payload, "shutdown") == true then
            confirmation.shutdown = true
        end
        local service = result_field(payload, "prepare_service_restart")
        if type(service) == "string" and service:match("%S") then
            confirmation.prepare_service_restart = service:match("^%s*(.-)%s*$")
        end
    end

    if confirmation.reboot or confirmation.shutdown
        or confirmation.prepare_service_restart then
        return confirmation
    end
    return nil
end

local function first_tool_message(calls)
    local fields = { "user_only", "result", "message", "error", "comment" }
    for _, call in ipairs(calls or {}) do
        for _, key in ipairs(fields) do
            local value = result_field(call.output, key)
            if type(value) == "string" and value:match("%S") then
                return value
            end
        end
    end
    return ""
end

local Runner = {}
Runner.__index = Runner

function Runner:_local_tools_enabled()
    if not common.check_function_calling_enabled(self.service)
        or (type(self.service.get_format) == "function"
            and self.service:get_format() == common.ai.format.title) then
        return false
    end
    local cursor = require("luci.model.uci").cursor()
    return cursor:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool") == true
end

function Runner:_check_tool_mode()
    -- Use the capability captured before sending this request, not current
    -- switches: changing them during a response must not bypass its mode guard.
    if not self.request_uses_local_tools then return true end
    local loaded, state = pcall(require, "oasis.local.tool.state")
    -- Core-only installations can chat without oasis-mod-tool. An old module
    -- is still rejected by the manager ABI check if a manager is requested.
    if not loaded or type(state) ~= "table" or type(state.get_mode) ~= "function" then return true end
    local cursor = require("luci.model.uci").cursor()
    local mode, err = state.get_mode(cursor)
    if not mode then
        return nil, build_error(self.service, "Failed to read the tool mode.", err.error)
    end
    if self.mode_token and self.mode_token ~= mode.token then
        return nil, build_error(self.service,
            "Tool mode changed during this request. Start a new request.",
            "Further tool execution was stopped; completed operations were not rolled back.")
    end
    self.mode_token = mode.token
    self.service._tool_mode_token = mode.token
    return true
end

function Runner:_preflight(descriptors, request_allows_tools)
    if request_allows_tools == false then
        return nil, build_error(
            self.service,
            "The AI requested another tool after tools were disabled.",
            self.deny_reason or "A final assistant response was required."
        )
    end
    if not self.request_uses_local_tools then
        return nil, build_error(self.service,
            "The AI requested a local tool when local tools were disabled.",
            "Local tools were not enabled for this request.")
    end
    local mode_ok, mode_err = self:_check_tool_mode()
    if not mode_ok then return nil, mode_err end
    if type(descriptors) ~= "table" or #descriptors == 0 then
        return nil, build_error(
            self.service,
            "The AI returned malformed tool call data.",
            "tool call batch is empty",
            "parse_error"
        )
    end
    if self.tool_rounds >= self.max_tool_rounds then
        return nil, build_error(
            self.service,
            "The tool sequence reached its tool-round limit.",
            "max_tool_rounds=" .. tostring(self.max_tool_rounds)
        )
    end
    if #descriptors > self.max_tool_calls - self.tool_calls then
        return nil, build_error(
            self.service,
            "The tool sequence reached its total tool-call limit.",
            "max_tool_calls=" .. tostring(self.max_tool_calls)
        )
    end

    local calls = {}
    local has_manager = false
    local has_normal = false
    for _, descriptor in ipairs(descriptors) do
        local call, why = normalize_call_descriptor(descriptor)
        if not call then
            return nil, build_error(
                self.service,
                "The AI returned malformed tool call data.",
                why,
                "parse_error"
            )
        end
        calls[#calls + 1] = call
        has_manager = has_manager or call.manager
        has_normal = has_normal or not call.manager
    end

    if has_manager and has_normal then
        return nil, build_error(
            self.service,
            "Tool Search management tools cannot be mixed with normal tools.",
            "Submit management and normal tool calls in separate rounds."
        )
    end

    if has_manager then
        -- Each manager mutation changes runtime state independently. Authorize only one
        -- management call per response so a later failure cannot leave a
        -- partially-applied multi-call batch.
        if #calls ~= 1 then
            return nil, build_error(
                self.service,
                "Tool Search management batches must contain exactly one call.",
                "Submit each management operation in a separate round."
            )
        end

        local arguments_ok, arguments_error =
            validate_manager_arguments(calls[1])
        if not arguments_ok then
            return nil, build_error(
                self.service,
                "The Tool Search management call has invalid arguments.",
                arguments_error,
                "parse_error"
            )
        end

        -- Management arguments have now passed their exact object contract.
        -- Canonicalize even an omitted get_tool_list argument as `{}` so a
        -- new provider call ID cannot evade the repeated-operation guard.
        local canonical_arguments, canonical_error =
            tool_policy.canonical_object(calls[1].arguments)
        if not canonical_arguments then
            return nil, build_error(
                self.service,
                "The Tool Search management call has invalid arguments.",
                canonical_error,
                "parse_error"
            )
        end
        calls[1].signature = calls[1].name .. "\0" .. canonical_arguments

        -- Never dispatch the volatile Auto contract into an older persistent
        -- manager implementation. The r11 state module
        -- publishes the ABI marker and functions checked here.
        local abi_ok, abi_error = validate_tool_search_abi(calls[1].name)
        if not abi_ok then
            return nil, build_error(
                self.service,
                "Tool Search requires a compatible oasis-mod-tool package.",
                abi_error .. "; install oasis-mod-tool r11 or newer",
                "internal_error"
            )
        end

        local in_batch = {}
        for _, call in ipairs(calls) do
            if self.manager_signatures[call.signature] or in_batch[call.signature] then
                return nil, build_error(
                    self.service,
                    "The Tool Search sequence repeated the same management operation.",
                    "tool=" .. call.name
                )
            end
            in_batch[call.signature] = true
        end
    end

    return {
        calls = calls,
        manager = has_manager,
        count = #calls,
    }
end

function Runner:_authorize_tool_batch(descriptors)
    if self.authorized_batch ~= nil then
        local err = build_error(
            self.service,
            "The AI service attempted to authorize more than one tool batch for one response.",
            "Only one tool batch may be dispatched per AI response.",
            "internal_error"
        )
        self.preflight_error = err
        return false, err
    end

    local batch, err = self:_preflight(descriptors, self.request_allows_tools)
    if not batch then
        self.preflight_error = err
        return false, err
    end
    -- Authorization itself has no side effect. Keep the exact normalized
    -- batch so the provider's post-execution tool_info can be matched before
    -- it is accepted for accounting or continuation.
    self.authorized_batch = batch
    return true
end

function Runner:_set_context(allow_tools, refresh_registry)
    local remaining_ai_requests = self.max_ai_requests - self.ai_requests
    local remaining_tool_rounds = self.max_tool_rounds - self.tool_rounds
    local remaining_tool_calls = self.max_tool_calls - self.tool_calls
    local can_request_tools = allow_tools
        and remaining_ai_requests > 1
        and remaining_tool_rounds > 0
        and remaining_tool_calls > 0

    self.request_allows_tools = can_request_tools
    self.request_uses_local_tools = can_request_tools and self:_local_tools_enabled()
    if allow_tools and not can_request_tools then
        self.deny_reason = "A sequence limit requires a final assistant response."
        if remaining_tool_rounds <= 0 then
            self.limit_kind = "tool_rounds"
        elseif remaining_tool_calls <= 0 then
            self.limit_kind = "tool_calls"
        else
            -- Reserve this last request for a final text response.
            self.limit_kind = "ai_requests"
        end
    elseif not allow_tools then
        self.deny_reason = "A normal tool batch has already completed."
    else
        self.deny_reason = nil
    end

    local context = {
        active = true,
        allow_followup_tools = can_request_tools,
        refresh_tool_registry = refresh_registry == true,
        remaining_ai_requests = remaining_ai_requests,
        remaining_tool_rounds = remaining_tool_rounds,
        remaining_tool_calls = remaining_tool_calls,
        authorize_tool_batch = function(calls)
            return self:_authorize_tool_batch(calls)
        end,
    }

    self.service._tool_sequence_context = context
    -- Compatibility for providers which have not yet adopted the explicit
    -- context. They already use _agent_mode to decide whether a tool-result
    -- follow-up may include another tool schema.
    self.service._agent_mode = can_request_tools

    if type(self.service.set_tool_sequence_context) == "function" then
        local ok, accepted, setter_error = pcall(function()
            return self.service:set_tool_sequence_context(context)
        end)
        if not ok or accepted == false then
            return nil, build_error(
                self.service,
                "Failed to configure the tool sequence for the AI service.",
                tostring(ok and setter_error or accepted),
                "internal_error"
            )
        end
    end
    return true
end

function Runner:_clear_context()
    if type(self.service.set_tool_sequence_context) == "function" then
        pcall(function()
            self.service:set_tool_sequence_context(nil)
        end)
    end
    self.service._tool_sequence_context = self.original_context
    self.service._agent_mode = self.original_agent_mode
    self.service._tool_mode_token = self.original_mode_token
end

function Runner:_parse_tool_info(raw)
    if type(raw) ~= "string" or #raw == 0 then
        return nil, build_error(
            self.service,
            "The AI returned malformed tool output.",
            "tool_info is not a non-empty JSON string",
            "parse_error"
        )
    end
    local parsed = decode_json(raw)
    local output_count = type(parsed) == "table"
        and dense_array_length(parsed.tool_outputs) or nil
    if output_count == nil or output_count == 0 then
        return nil, build_error(
            self.service,
            "The AI returned malformed tool output.",
            "tool_outputs is missing or empty",
            "parse_error"
        )
    end

    local calls = {}
    for index = 1, output_count do
        local descriptor = parsed.tool_outputs[index]
        local call, why = normalize_call_descriptor(descriptor)
        if not call then
            return nil, build_error(
                self.service,
                "The AI returned malformed tool output.",
                why,
                "parse_error"
            )
        end
        calls[#calls + 1] = call
    end

    local authorized = self.authorized_batch
    if type(authorized) ~= "table" or type(authorized.calls) ~= "table" then
        return nil, build_error(
            self.service,
            "The AI service returned tool output without sequence authorization.",
            "The provider did not authorize the executed tool batch.",
            "internal_error"
        )
    end
    if #calls ~= authorized.count then
        return nil, build_error(
            self.service,
            "The AI service returned tool output that did not match the authorized batch.",
            "authorized_count=" .. tostring(authorized.count)
                .. ", returned_count=" .. tostring(#calls),
            "internal_error"
        )
    end
    for index, call in ipairs(calls) do
        local expected = authorized.calls[index]
        if type(expected) ~= "table" or call.id ~= expected.id
            or call.signature ~= expected.signature then
            return nil, build_error(
                self.service,
                "The AI service returned tool output that did not match the authorized batch.",
                "tool_index=" .. tostring(index),
                "internal_error"
            )
        end
    end

    local batch = {
        calls = calls,
        manager = authorized.manager,
        count = authorized.count,
    }
    self.authorized_batch = nil
    batch.parsed_info = parsed
    batch.raw = raw

    for index, descriptor in ipairs(parsed.tool_outputs) do
        local output = descriptor.output
        if type(output) == "string" then
            output = decode_json(output)
        end
        if type(output) ~= "table" then
            return batch, build_error(
                self.service,
                "A tool returned malformed output.",
                "tool=" .. batch.calls[index].name,
                "parse_error"
            )
        end
        batch.calls[index].output = output
        batch.calls[index].raw = descriptor

        local error_value = result_field(output, "error")
        local status = result_field(output, "status")
        if result_field(output, "code") == "tool_mode_changed" then
            return batch, build_error(self.service,
                "Tool mode changed during this request. Start a new request.",
                "Further tool execution was stopped; completed operations were not rolled back.")
        end
        if batch.calls[index].manager and (has_error_value(error_value)
            or status ~= "OK") then
            return batch, build_error(
                self.service,
                "A Tool Search management operation reported a failure.",
                "tool=" .. batch.calls[index].name
                    .. ", status=" .. tostring(status or error_value)
            )
        end
        if batch.calls[index].name == "get_tool_list"
            and dense_array_length(result_field(output, "tool")) == nil then
            return batch, build_error(
                self.service,
                "Tool Search returned a malformed tool list.",
                "tool=get_tool_list",
                "parse_error"
            )
        end
    end

    return batch
end

function Runner:_merge_tool_info(parsed)
    if not self.aggregate then
        self.aggregate = { tool_outputs = {} }
    end
    if self.aggregate.service == nil and parsed.service ~= nil then
        self.aggregate.service = parsed.service
    end
    self.aggregate.reboot = self.aggregate.reboot == true or parsed.reboot == true
    self.aggregate.shutdown = self.aggregate.shutdown == true or parsed.shutdown == true
    for _, output in ipairs(parsed.tool_outputs or {}) do
        self.aggregate.tool_outputs[#self.aggregate.tool_outputs + 1] = output
    end
end

function Runner:_tool_info_json()
    if not self.aggregate then
        return nil
    end
    local ok, encoded = pcall(jsonc.stringify, self.aggregate, false)
    if ok and type(encoded) == "string" then
        return encoded
    end
    return nil
end

function Runner:_result(fields)
    fields = fields or {}
    fields.ok = fields.ok == true
    fields.state = fields.state or (fields.ok and "DONE" or "FAILED")
    fields.turns = self.ai_requests
    fields.tool_rounds = self.tool_rounds
    fields.tool_calls = self.tool_calls
    fields.last_tool_names = self.last_tool_names
    fields.tool_info = fields.tool_info or self:_tool_info_json()
    if self.limit_kind then
        fields.limit_reached = true
        fields.stop_reason = "limit_reached"
        fields.limit_kind = self.limit_kind
        if type(fields.error) == "table" then
            fields.error.stop_reason = fields.stop_reason
            fields.error.limit_kind = self.limit_kind
        end
    end
    return fields
end

function Runner:_fail(err, state, fields)
    fields = fields or {}
    if type(err) == "table" and (self.tool_response_seen
        or self.tool_calls > 0
        or has_committed_tool_side_effects(self.service)) then
        err.can_continue = false
        err.display = chat_error.format(err)
    end
    fields.ok = false
    fields.state = state or "FAILED"
    fields.error = err
    fields.message = fields.message or chat_error.format(err)
    return self:_result(fields)
end

function Runner:_run()
    if type(self.service.begin_tool_sequence) == "function" then
        local begin_ok, begun, begin_error = pcall(function()
            return self.service:begin_tool_sequence()
        end)
        if not begin_ok or begun == false then
            return self:_fail(build_error(
                self.service,
                "Failed to initialize the tool sequence state.",
                tostring(begin_ok and begin_error or begun),
                "internal_error"
            ))
        end
    end

    local allow_tools = true
    local refresh_registry = false

    while self.ai_requests < self.max_ai_requests do
        local context_ok, context_err = self:_set_context(allow_tools, refresh_registry)
        if not context_ok then
            return self:_fail(context_err)
        end
        local mode_ok, mode_err = self:_check_tool_mode()
        if not mode_ok then return self:_fail(mode_err) end
        refresh_registry = false
        self.preflight_error = nil
        self.authorized_batch = nil
        self.ai_requests = self.ai_requests + 1

        local call_ok, first, plain_text, tool_used, err = pcall(
            transfer.chat_with_ai, self.service, self.chat)
        if not call_ok then
            return self:_fail(build_error(
                self.service,
                "The AI request failed inside the tool sequence.",
                tostring(first),
                "internal_error"
            ))
        end
        if tool_used == true then
            -- All built-in providers set this only after dispatching the
            -- authorized batch. Treat malformed/missing tool_info as unsafe to
            -- retry even when accounting cannot be completed.
            self.tool_response_seen = true
        end
        if self.preflight_error then
            return self:_fail(self.preflight_error)
        end
        if err then
            if type(err) ~= "table" then
                err = build_error(
                    self.service,
                    "The AI request failed during the tool sequence.",
                    tostring(err),
                    "internal_error"
                )
            end
            if (self.tool_calls > 0 or self.tool_response_seen)
                and type(err) == "table" then
                err.can_continue = false
                err.display = chat_error.format(err)
            end
            return self:_fail(err)
        end

        if not tool_used then
            -- authorized_batch belongs to this provider response. The service
            -- side-effect marker is cumulative for the whole sequence and is
            -- intentionally used only by _fail() to close retryability; after
            -- a successful tool round it remains true during the valid final
            -- no-tool response.
            if self.authorized_batch ~= nil then
                return self:_fail(build_error(
                    self.service,
                    "The AI service did not return the authorized tool result.",
                    "A tool batch was authorized or dispatched but tool_used was false.",
                    "internal_error"
                ))
            end
            local message = tostring(plain_text or "")
            if self.detect_need_input then
                local requested = message:gsub("^%s+", ""):match("^NEED_INPUT:%s*(.*)$")
                if requested then
                    return self:_result({
                        ok = false,
                        state = "NEED_INPUT",
                        message = requested,
                        new_chat_info = first,
                    })
                end
            end
            if self.limit_kind then
                local notice = "The tool sequence reached its "
                    .. self.limit_kind .. " limit. Further tool execution was stopped;"
                    .. " the requested work may be incomplete."
                local detail = string.format("requests=%d rounds=%d calls=%d",
                    self.ai_requests, self.tool_rounds, self.tool_calls)
                if #message > 0 then
                    detail = detail .. "\nFinal assistant response: " .. message
                end
                return self:_fail(build_error(self.service, notice, detail,
                    "limit_reached"), "STUCK", {
                    message = #message > 0 and (message .. "\n\n" .. notice) or notice,
                    final_response = message,
                    new_chat_info = first,
                })
            end
            return self:_result({
                ok = true,
                state = "DONE",
                message = message,
                new_chat_info = first,
            })
        end

        local batch, batch_err = self:_parse_tool_info(first)
        if not batch then
            return self:_fail(batch_err)
        end

        self.tool_rounds = self.tool_rounds + 1
        self.tool_calls = self.tool_calls + batch.count
        self.last_tool_names = {}
        for _, call in ipairs(batch.calls) do
            self.last_tool_names[#self.last_tool_names + 1] = call.name
            if call.manager then
                self.manager_signatures[call.signature] = true
            end
        end
        self:_merge_tool_info(batch.parsed_info)

        if batch_err then
            return self:_fail(batch_err)
        end

        if type(self.service.handle_tool_output) ~= "function" then
            return self:_fail(build_error(
                self.service,
                "The selected AI service has no tool-output handler."
            ))
        end
        local handled_ok, handled = pcall(function()
            return self.service:handle_tool_output(first, self.chat)
        end)
        if not handled_ok or not handled then
            return self:_fail(build_error(
                self.service,
                "Failed to handle tool output.",
                handled_ok and nil or tostring(handled)
            ))
        end

        local confirmation = confirmation_from(batch.parsed_info, batch.calls)
        if confirmation and self.stop_on_confirmation then
            local confirmation_err = build_error(
                self.service,
                "A tool operation requires user confirmation.",
                first_tool_message(batch.calls)
            )
            confirmation_err.confirmation = confirmation
            local confirmation_message = first_tool_message(batch.calls)
            if confirmation_message == "" then
                confirmation_message = "Confirmation required"
            end
            return self:_fail(confirmation_err, "NEED_CONFIRMATION", {
                confirmation = confirmation,
                message = confirmation_message,
            })
        end

        if batch.manager then
            allow_tools = true
            refresh_registry = true
        else
            allow_tools = self.allow_normal_tool_chaining
        end
    end

    return self:_fail(build_error(
        self.service,
        "The tool sequence reached its AI-request limit.",
        "max_ai_requests=" .. tostring(self.max_ai_requests)
    ), "STUCK")
end

function M.run(service, chat, opts)
    opts = opts or {}
    if type(service) ~= "table" or type(chat) ~= "table" then
        local err = build_error(
            service,
            "The tool sequence received invalid input.",
            "service and chat must be tables",
            "internal_error"
        )
        return {
            ok = false,
            state = "FAILED",
            error = err,
            message = chat_error.format(err),
            turns = 0,
            tool_rounds = 0,
            tool_calls = 0,
            last_tool_names = {},
        }
    end

    local runner = setmetatable({
        service = service,
        chat = chat,
        max_ai_requests = bounded_limit(
            opts.max_ai_requests, HARD_MAX_AI_REQUESTS, HARD_MAX_AI_REQUESTS),
        max_tool_rounds = bounded_limit(
            opts.max_tool_rounds, HARD_MAX_TOOL_ROUNDS, HARD_MAX_TOOL_ROUNDS),
        max_tool_calls = bounded_limit(
            opts.max_tool_calls, HARD_MAX_TOOL_CALLS, HARD_MAX_TOOL_CALLS),
        allow_normal_tool_chaining = opts.allow_normal_tool_chaining == true,
        detect_need_input = opts.detect_need_input == true,
        stop_on_confirmation = opts.stop_on_confirmation == true,
        ai_requests = 0,
        tool_rounds = 0,
        tool_calls = 0,
        last_tool_names = {},
        manager_signatures = {},
        original_context = service._tool_sequence_context,
        original_agent_mode = service._agent_mode,
        original_mode_token = service._tool_mode_token,
    }, Runner)

    local ok, result = xpcall(function()
        return runner:_run()
    end, function(err)
        return tostring(err)
    end)
    runner:_clear_context()

    if ok then
        return result
    end
    return runner:_fail(build_error(
        service,
        "The tool sequence failed unexpectedly.",
        result,
        "internal_error"
    ))
end

M.MAX_AI_REQUESTS = HARD_MAX_AI_REQUESTS
M.MAX_TOOL_ROUNDS = HARD_MAX_TOOL_ROUNDS
M.MAX_TOOL_CALLS = HARD_MAX_TOOL_CALLS
M.MANAGER_TOOLS = MANAGER_TOOLS
M.REQUIRED_TOOL_SEARCH_ABI = REQUIRED_TOOL_SEARCH_ABI

return M
