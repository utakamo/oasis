#!/usr/bin/env lua

-- Bounded orchestration for AI tool calls.
--
-- Normal turns use one tool batch. Optional execution policies decide whether
-- subsequent tool requests are permitted; authorization and accounting stay here.

local jsonc      = require("luci.jsonc")
local chat_error = require("oasis.chat.error")
local transfer   = require("oasis.chat.transfer")
local tool_policy = require("oasis.chat.function.calling.policy")
local common     = require("oasis.common")

local M = {}

local HARD_MAX_AI_REQUESTS = 6
local HARD_MAX_TOOL_ROUNDS = 4
local HARD_MAX_TOOL_CALLS = 8
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

    local canonical, canonical_error = tool_policy.canonical_object(arguments)
    if not canonical then return nil, "tool arguments are invalid JSON: " .. tostring(canonical_error) end
    local signature = name .. "\0" .. canonical

    local raw_id = call.tool_call_id
    if raw_id == nil then
        raw_id = call.id
    end

    return {
        id = raw_id == nil and nil or tostring(raw_id),
        name = name,
        arguments = arguments,
        signature = signature,
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
    local cursor = require("luci.model.uci").cursor()
    local mode, err = require("oasis.mode").read(cursor)
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
    for _, descriptor in ipairs(descriptors) do
        local call, why = normalize_call_descriptor(descriptor)
        if not call then
            return nil, build_error(self.service, "The AI returned malformed tool call data.", why, "parse_error")
        end
        calls[#calls + 1] = call
    end
    local refresh_registry = false
    if self.policy then
        local allowed, result = self.policy:validate_batch(calls)
        if not allowed then return nil, result end
        refresh_registry = result == true
    end
    return { calls = calls, refresh_registry = refresh_registry, count = #calls }

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
    self.service._oasis_execution = self.original_execution
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
        refresh_registry = authorized.refresh_registry,
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
        if self.policy then
            local policy_error = self.policy:validate_result(batch.calls[index], result_field, dense_array_length)
            if policy_error then return batch, policy_error end
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
    fields.stop_reason = fields.stop_reason or (fields.error and fields.error.stop_reason)
        or (fields.ok and "completed" or "execution_error")
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
    if self.max_ai_requests > 1 and self:_local_tools_enabled() then
        local execution, err = require("oasis.mode").resolve_execution(self.service)
        if not execution then
            return self:_fail(build_error(self.service, err.error, err.code, "unsupported_feature"))
        end
        self.service._oasis_execution = execution
        self.mode_token = execution.token
        self.policy = execution.policy
        if self.policy then
            self.max_ai_requests = bounded_limit(self.opts.max_ai_requests, self.policy.max_ai_requests, self.policy.max_ai_requests)
            self.max_tool_rounds = bounded_limit(self.opts.max_tool_rounds, self.policy.max_tool_rounds, self.policy.max_tool_rounds)
            self.max_tool_calls = bounded_limit(self.opts.max_tool_calls, self.policy.max_tool_calls, self.policy.max_tool_calls)
            self.detect_need_input = self.policy.stop_on_input
            self.stop_on_confirmation = self.policy.stop_on_confirmation
        end
    end
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
                        ok = true,
                        state = "NEED_INPUT",
                        stop_reason = "input_required",
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
            return self:_result({
                ok = true, state = "NEED_CONFIRMATION", stop_reason = "confirmation_required",
                confirmation = confirmation, pause_from_tool = true,
                message = "User confirmation is required.",
            })
        end

        if self.policy and self.policy.stop_on_input then
            for _, call in ipairs(batch.calls) do
                if result_field(call.output, "ui_action") ~= nil then
                    return self:_result({ok=true, state="NEED_INPUT", stop_reason="input_required",
                        pause_from_tool=true, message="User input is required."})
                end
            end
        end

        if batch.refresh_registry then
            allow_tools = true
            refresh_registry = true
        else
            allow_tools = self.policy and self.policy.continue_tools == true or false
            refresh_registry = allow_tools
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
        opts = opts,
        original_execution = service._oasis_execution,
        max_ai_requests = bounded_limit(
            opts.max_ai_requests, HARD_MAX_AI_REQUESTS, HARD_MAX_AI_REQUESTS),
        max_tool_rounds = bounded_limit(
            opts.max_tool_rounds, HARD_MAX_TOOL_ROUNDS, HARD_MAX_TOOL_ROUNDS),
        max_tool_calls = bounded_limit(
            opts.max_tool_calls, HARD_MAX_TOOL_CALLS, HARD_MAX_TOOL_CALLS),
        detect_need_input = false,
        stop_on_confirmation = false,
        ai_requests = 0,
        tool_rounds = 0,
        tool_calls = 0,
        last_tool_names = {},
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

    local recorder = require("oasis.chat.recorder")
    if ok then
        return recorder.finish(service, result)
    end
    return recorder.finish(service, runner:_fail(build_error(
        service,
        "The tool sequence failed unexpectedly.",
        result,
        "internal_error"
    )))
end

M.MAX_AI_REQUESTS = HARD_MAX_AI_REQUESTS
M.MAX_TOOL_ROUNDS = HARD_MAX_TOOL_ROUNDS
M.MAX_TOOL_CALLS = HARD_MAX_TOOL_CALLS

return M
