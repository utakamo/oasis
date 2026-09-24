local jsonc = require("luci.jsonc")
local chat_error = require("oasis.chat.error")
local transfer = require("oasis.chat.transfer")
local tool_sequence = require("oasis.chat.tool_sequence")

local M = {}

local function encode(value)
    return jsonc.stringify(value, false)
end

local function decode(value)
    local ok, decoded = pcall(jsonc.parse, value)
    if ok then
        return decoded
    end
    return nil
end

local function call(name, arguments, output, id)
    return {
        name = name,
        arguments = arguments or {},
        tool_call_id = id or ("call-" .. name),
        output = output or { status = "OK" },
    }
end

local function tool_list_call()
    return call("get_tool_list", {}, {
        status = "OK",
        tool = {
            {
                server = "fixture.weather",
                name = "weather",
                enabled = false,
                conflicted = false,
            },
        },
    }, "call-list")
end

local function enable_call()
    return call("set_tool_enabled", {
        server = "fixture.weather",
        tool = "weather",
    }, {
        status = "OK",
        changed = true,
        server = "fixture.weather",
        tool = "weather",
        enabled = true,
    }, "call-enable")
end

local function normal_call(output)
    return call("weather", { city = "Tokyo" }, output or {
        status = "OK",
        temperature = 28,
    }, "call-weather")
end

local function context_snapshot(context)
    if type(context) ~= "table" then
        return nil
    end
    return {
        active = context.active,
        allow_followup_tools = context.allow_followup_tools,
        refresh_tool_registry = context.refresh_tool_registry,
        remaining_ai_requests = context.remaining_ai_requests,
        remaining_tool_rounds = context.remaining_tool_rounds,
        remaining_tool_calls = context.remaining_tool_calls,
        has_authorizer = type(context.authorize_tool_batch) == "function",
    }
end

local function new_service(options)
    options = options or {}
    local service = {
        _tool_sequence_context = options.original_context,
        _agent_mode = options.original_agent_mode,
        context_updates = {},
        context_clear_calls = 0,
        begin_calls = 0,
        handled_outputs = {},
        tool_side_effects_committed = false,
    }

    function service:get_config()
        return {
            service = "FixtureAI",
            model = "fixture-model",
            function_calling = "1",
        }
    end

    function service:set_tool_sequence_context(context)
        self.provider_context = context
        if context == nil then
            self.context_clear_calls = self.context_clear_calls + 1
        else
            self.context_updates[#self.context_updates + 1] = context_snapshot(context)
        end
        if options.context_error and context ~= nil then
            error(options.context_error)
        end
        if options.context_result == false and context ~= nil then
            return false, options.context_result_error or "context rejected"
        end
        return true
    end

    function service:begin_tool_sequence()
        self.begin_calls = self.begin_calls + 1
        if options.begin_error then
            error(options.begin_error)
        end
        if options.begin_result == false then
            return false, options.begin_result_error or "begin rejected"
        end
        return true
    end

    function service:handle_tool_output(tool_info, chat)
        self.handled_outputs[#self.handled_outputs + 1] = tool_info
        if options.handle_error then
            error(options.handle_error)
        end
        if options.handle_result == false then
            return false
        end
        return true
    end

    function service:get_tool_side_effects_committed()
        return self.tool_side_effects_committed == true
    end

    return service
end

local function install_manager_registry(t, steps)
    local sections
    local needs_registry = false
    for _, step in ipairs(steps or {}) do
        for _, descriptor in ipairs(step.calls or {}) do
            if tool_sequence.MANAGER_TOOLS[descriptor.name] then
                needs_registry = true
                if step.registry_sections ~= nil then
                    sections = step.registry_sections
                end
            end
        end
    end
    sections = sections or {
        {
            [".name"] = "manager-list",
            server = "oasis.tool.manager",
            name = "get_tool_list",
            enable = "1",
            conflict = "0",
        },
        {
            [".name"] = "manager-enable",
            server = "oasis.tool.manager",
            name = "set_tool_enabled",
            enable = "1",
            conflict = "0",
        },
        {
            [".name"] = "manager-disable",
            server = "oasis.tool.manager",
            name = "set_tool_disabled",
            enable = "1",
            conflict = "0",
        },
    }

    local module_name = "luci.model.uci"
    local original = package.loaded[module_name]
    local original_store = package.loaded["oasis.local.tool.auto_store"]
    local support = { local_tool = "1", tool_auto = needs_registry and "1" or "0" }
    package.loaded["oasis.local.tool.auto_store"] = {
        read = function() return { version = 1, enabled = {} } end,
    }
    package.loaded[module_name] = {
        cursor = function()
            return {
                get_all = function() return support end,
                get_bool = function(_, _, _, option) return support[option] == "1" end,
                foreach = function(self, config, section_type, callback)
                    for _, section in ipairs(sections) do
                        callback(section)
                    end
                    return true
                end,
            }
        end,
    }
    t:on_cleanup(function()
        package.loaded[module_name] = original
        package.loaded["oasis.local.tool.auto_store"] = original_store
    end)
    return support
end

local function install_script(t, steps)
    local support = install_manager_registry(t, steps)
    local original = transfer.chat_with_ai
    local trace = {
        requests = 0,
        authorizations = 0,
        side_effects = 0,
        contexts = {},
        side_effect_markers = {},
        support = support,
    }
    t:on_cleanup(function()
        transfer.chat_with_ai = original
    end)

    transfer.chat_with_ai = function(service, chat)
        trace.requests = trace.requests + 1
        local context = service._tool_sequence_context
        trace.contexts[trace.requests] = context_snapshot(context)
        trace.side_effect_markers[trace.requests] =
            service:get_tool_side_effects_committed()
        local step = steps[trace.requests]
        if not step then
            error("fixture script exhausted at request " .. trace.requests)
        end
        if step.mode_generation then
            support.tool_auto_generation = step.mode_generation
        end

        if step.kind == "throw" then
            error(step.message or "fixture provider exception")
        end
        if step.kind == "error" then
            return nil, nil, false, step.error
        end
        if step.kind == "final" then
            return step.new_chat_info, step.message or "final", false, nil
        end
        if step.kind ~= "tool" then
            error("unknown fixture step: " .. tostring(step.kind))
        end

        if not step.skip_authorization then
            trace.authorizations = trace.authorizations + 1
            local allowed, authorization_error =
                context.authorize_tool_batch(step.calls)
            if not allowed then
                return nil, nil, false, authorization_error
            end
        end
        service.tool_side_effects_committed = true
        trace.side_effects = trace.side_effects + #step.calls

        local tool_info = {
            service = step.service or "fixture-provider",
            tool_outputs = step.return_calls or step.calls,
            reboot = step.reboot,
            shutdown = step.shutdown,
        }
        return encode(tool_info), nil, true, nil
    end

    return trace
end

local function assert_failed(t, result)
    t:assert_false(result.ok)
    t:assert_type("table", result.error)
    t:assert_false(result.error.can_continue)
end

function M.register(harness)
    harness:test("unit", "mode changes reject further dispatch and restore the service token", function(t)
        local service = new_service()
        service._tool_mode_token = "outer-token"
        local trace = install_script(t, {
            { kind = "tool", calls = { tool_list_call() } },
            { kind = "tool", calls = { enable_call() }, mode_generation = "2" },
        })
        local result = tool_sequence.run(service, { messages = {} })
        t:assert_false(result.ok)
        t:assert_contains(result.error.message, "Tool mode changed")
        t:assert_false(result.error.can_continue)
        t:assert_equal(1, trace.side_effects)
        t:assert_equal("outer-token", service._tool_mode_token)

        local first = new_service()
        local first_trace = install_script(t, {
            { kind = "tool", calls = { normal_call() }, mode_generation = "1" },
        })
        local first_result = tool_sequence.run(first, { messages = {} })
        t:assert_false(first_result.ok)
        t:assert_true(first_result.error.can_continue)
        t:assert_equal(0, first_trace.side_effects)
    end)

    harness:test("unit", "dispatch mode-change errors stop normal tool continuations", function(t)
        local service = new_service()
        local trace = install_script(t, {
            { kind = "tool", calls = { normal_call({ status = "NG",
                code = "tool_mode_changed", error = "Start a new request." }) } },
        })
        local result = tool_sequence.run(service, { messages = {} })
        t:assert_false(result.ok)
        t:assert_contains(result.error.message, "Tool mode changed")
        t:assert_equal(1, trace.requests)
        t:assert_equal(0, #service.handled_outputs)
    end)

    harness:test("unit", "tool sequence returns a direct answer after one request", function(t)
        local service = new_service()
        local trace = install_script(t, {
            {
                kind = "final",
                message = "direct answer",
                new_chat_info = '{"id":"chat-1"}',
            },
        })

        local result = tool_sequence.run(service, { messages = {} })
        t:assert_true(result.ok)
        t:assert_equal("DONE", result.state)
        t:assert_equal("direct answer", result.message)
        t:assert_equal('{"id":"chat-1"}', result.new_chat_info)
        t:assert_equal(1, result.turns)
        t:assert_equal(0, result.tool_rounds)
        t:assert_equal(0, result.tool_calls)
        t:assert_equal(1, trace.requests)
        t:assert_equal(1, service.begin_calls)
        t:assert_true(trace.contexts[1].allow_followup_tools)
        t:assert_true(trace.contexts[1].has_authorizer)
        t:assert_nil(service._tool_sequence_context)
        t:assert_nil(service._agent_mode)
        t:assert_nil(service.provider_context)
    end)

    harness:test("unit", "normal tools get exactly one final answer request", function(t)
        local service = new_service()
        local trace = install_script(t, {
            { kind = "tool", calls = { normal_call() } },
            { kind = "final", message = "Tokyo is 28 C" },
        })

        local result = tool_sequence.run(service, { messages = {} })
        t:assert_true(result.ok)
        t:assert_equal("Tokyo is 28 C", result.message)
        t:assert_equal(2, result.turns)
        t:assert_equal(1, result.tool_rounds)
        t:assert_equal(1, result.tool_calls)
        t:assert_equal(1, trace.side_effects)
        t:assert_true(trace.contexts[1].allow_followup_tools)
        t:assert_false(trace.contexts[2].allow_followup_tools)
        t:assert_false(trace.contexts[2].refresh_tool_registry)
        t:assert_equal(1, #service.handled_outputs)
        local aggregate = decode(result.tool_info)
        t:assert_type("table", aggregate)
        t:assert_equal(1, #aggregate.tool_outputs)
        t:assert_equal("weather", aggregate.tool_outputs[1].name)
    end)

    harness:test("unit", "agent mode may chain normal tools before a final answer", function(t)
        local second_call = normal_call({
            status = "OK",
            temperature = 31,
        })
        second_call.arguments = { city = "Osaka" }
        second_call.tool_call_id = "call-weather-osaka"

        local service = new_service()
        local trace = install_script(t, {
            { kind = "tool", calls = { normal_call() } },
            { kind = "tool", calls = { second_call } },
            { kind = "final", message = "Tokyo is 28 C and Osaka is 31 C" },
        })

        local result = tool_sequence.run(
            service,
            { messages = {} },
            { allow_normal_tool_chaining = true }
        )
        t:assert_true(result.ok)
        t:assert_equal("DONE", result.state)
        t:assert_equal("Tokyo is 28 C and Osaka is 31 C", result.message)
        t:assert_equal(3, result.turns)
        t:assert_equal(2, result.tool_rounds)
        t:assert_equal(2, result.tool_calls)
        t:assert_equal(2, trace.side_effects)
        t:assert_true(trace.contexts[1].allow_followup_tools)
        t:assert_true(trace.contexts[2].allow_followup_tools)
        t:assert_true(trace.contexts[3].allow_followup_tools)
        t:assert_equal(2, #service.handled_outputs)
        local aggregate = decode(result.tool_info)
        t:assert_type("table", aggregate)
        t:assert_equal(2, #aggregate.tool_outputs)
        t:assert_equal("Tokyo",
            aggregate.tool_outputs[1].arguments.city)
        t:assert_equal("Osaka",
            aggregate.tool_outputs[2].arguments.city)
    end)

    harness:test("unit", "agent mode exposes NEED_INPUT without losing tool results", function(t)
        local service = new_service()
        local trace = install_script(t, {
            { kind = "tool", calls = { normal_call() } },
            {
                kind = "final",
                message = "  NEED_INPUT: Which weather station should I use?",
            },
        })

        local result = tool_sequence.run(service, { messages = {} }, {
            allow_normal_tool_chaining = true,
            detect_need_input = true,
        })
        t:assert_false(result.ok)
        t:assert_equal("NEED_INPUT", result.state)
        t:assert_equal("Which weather station should I use?", result.message)
        t:assert_nil(result.error)
        t:assert_equal(2, result.turns)
        t:assert_equal(1, result.tool_rounds)
        t:assert_equal(1, result.tool_calls)
        t:assert_equal(1, trace.side_effects)
        t:assert_equal(1, #service.handled_outputs)
        local aggregate = decode(result.tool_info)
        t:assert_type("table", aggregate)
        t:assert_equal(1, #aggregate.tool_outputs)
    end)

    harness:test("unit", "agent normal chaining stops at the configured round limit", function(t)
        local second_call = normal_call()
        second_call.arguments = { city = "Osaka" }
        second_call.tool_call_id = "call-weather-osaka"

        local service = new_service()
        local trace = install_script(t, {
            { kind = "tool", calls = { normal_call() } },
            { kind = "tool", calls = { second_call } },
        })

        local result = tool_sequence.run(service, { messages = {} }, {
            allow_normal_tool_chaining = true,
            max_tool_rounds = 1,
        })
        assert_failed(t, result)
        t:assert_contains(result.error.message,
            "requested another tool after tools were disabled")
        t:assert_equal(2, result.turns)
        t:assert_equal(1, result.tool_rounds)
        t:assert_equal(1, result.tool_calls)
        t:assert_equal(2, trace.authorizations)
        t:assert_equal(1, trace.side_effects)
        t:assert_true(trace.contexts[1].allow_followup_tools)
        t:assert_false(trace.contexts[2].allow_followup_tools)
        t:assert_equal(1, #service.handled_outputs)
    end)

    harness:test("unit", "budget-limited final answers report STUCK and retain partial results", function(t)
        for _, limits in ipairs({
            { max_tool_rounds = 1, kind = "tool_rounds" },
            { max_tool_calls = 1, kind = "tool_calls" },
            { max_ai_requests = 2, kind = "ai_requests" },
        }) do
            local service = new_service()
            local trace = install_script(t, {
                { kind = "tool", calls = { tool_list_call() } },
                { kind = "final", message = "The tool has not been enabled yet.",
                    new_chat_info = '{"id":"limited-chat"}' },
            })
            local result = tool_sequence.run(service, { messages = {} }, limits)
            assert_failed(t, result)
            t:assert_equal("STUCK", result.state)
            t:assert_true(result.limit_reached)
            t:assert_equal("limit_reached", result.stop_reason)
            t:assert_equal(limits.kind, result.limit_kind)
            t:assert_equal("limit_reached", result.error.kind)
            t:assert_equal(limits.kind, result.error.limit_kind)
            t:assert_equal("The tool has not been enabled yet.", result.final_response)
            t:assert_contains(result.message, "limit")
            t:assert_contains(result.message, result.final_response)
            t:assert_contains(chat_error.to_status(result.error).error.message, "limit")
            t:assert_contains(result.error.display, result.final_response)
            t:assert_equal('{"id":"limited-chat"}', result.new_chat_info)
            t:assert_equal(1, #decode(result.tool_info).tool_outputs)
            t:assert_equal(2, trace.requests)
            t:assert_equal(1, trace.side_effects)
            t:assert_false(trace.contexts[2].allow_followup_tools)
            t:assert_nil(service._tool_sequence_context)
        end
    end)

    harness:test("unit", "ordinary final answers at a budget boundary remain successful", function(t)
        local service = new_service()
        local trace = install_script(t, {
            { kind = "tool", calls = { normal_call() } },
            { kind = "final", message = "Tokyo is 28 C" },
        })
        local result = tool_sequence.run(service, { messages = {} }, {
            max_tool_rounds = 1, max_tool_calls = 1, max_ai_requests = 2,
        })
        t:assert_true(result.ok)
        t:assert_equal("DONE", result.state)
        t:assert_nil(result.limit_reached)
        t:assert_nil(result.stop_reason)
        t:assert_equal(2, trace.requests)
        t:assert_equal(1, trace.side_effects)
    end)

    harness:test("unit", "argument arrays survive sequence authorization and result matching", function(t)
        local service = new_service()
        local descriptor = normal_call()
        descriptor.arguments = '{"items":[[],1,null,3]}'
        local trace = install_script(t, {
            { kind = "tool", calls = { descriptor } },
            { kind = "final", message = "done" },
        })
        local result = tool_sequence.run(service, { messages = {} })
        t:assert_true(result.ok)
        t:assert_equal(1, trace.side_effects)
        t:assert_equal(descriptor.arguments, decode(result.tool_info).tool_outputs[1].arguments)
    end)

    harness:test("unit", "a cumulative side-effect marker permits the final response", function(t)
        local service = new_service()
        local trace = install_script(t, {
            { kind = "tool", calls = { normal_call() } },
            { kind = "final", message = "final after a dispatched tool" },
        })

        local result = tool_sequence.run(service, { messages = {} })
        t:assert_true(result.ok)
        t:assert_equal("DONE", result.state)
        t:assert_equal("final after a dispatched tool", result.message)
        t:assert_false(trace.side_effect_markers[1])
        t:assert_true(trace.side_effect_markers[2])
        t:assert_true(service:get_tool_side_effects_committed())
        t:assert_equal(2, trace.requests)
        t:assert_equal(1, trace.side_effects)
    end)

    harness:test("unit", "Tool Search refreshes schemas across a bounded multi-step turn", function(t)
        local service = new_service()
        local trace = install_script(t, {
            { kind = "tool", calls = { tool_list_call() } },
            { kind = "tool", calls = { enable_call() } },
            { kind = "tool", calls = { normal_call() } },
            { kind = "final", message = "The enabled weather tool reports 28 C" },
        })

        local result = tool_sequence.run(service, { messages = {} })
        t:assert_true(result.ok)
        t:assert_equal(4, result.turns)
        t:assert_equal(3, result.tool_rounds)
        t:assert_equal(3, result.tool_calls)
        t:assert_equal(3, trace.side_effects)
        t:assert_false(trace.contexts[1].refresh_tool_registry)
        t:assert_true(trace.contexts[2].allow_followup_tools)
        t:assert_true(trace.contexts[2].refresh_tool_registry)
        t:assert_true(trace.contexts[3].refresh_tool_registry)
        t:assert_false(trace.contexts[4].allow_followup_tools)
        t:assert_false(trace.contexts[4].refresh_tool_registry)
        t:assert_equal(3, #service.handled_outputs)

        local aggregate = decode(result.tool_info)
        t:assert_type("table", aggregate)
        t:assert_equal("fixture-provider", aggregate.service)
        t:assert_equal(3, #aggregate.tool_outputs)
        t:assert_equal("get_tool_list", aggregate.tool_outputs[1].name)
        t:assert_equal("set_tool_enabled", aggregate.tool_outputs[2].name)
        t:assert_equal("weather", aggregate.tool_outputs[3].name)
    end)

    harness:test("unit", "failed Tool Search mutations stop the sequence", function(t)
        local service = new_service()
        local failed_call = enable_call()
        failed_call.output = {
            status = "NG",
            changed = false,
            error = "UCI commit failed",
        }
        local trace = install_script(t, {
            { kind = "tool", calls = { failed_call } },
        })

        local result = tool_sequence.run(service, { messages = {} })
        assert_failed(t, result)
        t:assert_contains(result.error.message, "management operation")
        t:assert_equal(1, result.turns)
        t:assert_equal(1, result.tool_rounds)
        t:assert_equal(1, result.tool_calls)
        t:assert_equal(1, trace.side_effects)
        t:assert_equal(0, #service.handled_outputs)
    end)

    harness:test("unit", "mixed management and normal batches are rejected before execution", function(t)
        local service = new_service()
        local trace = install_script(t, {
            {
                kind = "tool",
                calls = { tool_list_call(), normal_call() },
            },
        })

        local result = tool_sequence.run(service, { messages = {} })
        t:assert_false(result.ok)
        t:assert_type("table", result.error)
        t:assert_true(result.error.can_continue)
        t:assert_contains(result.error.message, "cannot be mixed")
        t:assert_equal(1, trace.authorizations)
        t:assert_equal(0, trace.side_effects)
        t:assert_equal(0, result.tool_rounds)
        t:assert_equal(0, result.tool_calls)
        t:assert_equal(0, #service.handled_outputs)
    end)

    harness:test("unit", "management batches contain one exact-contract call", function(t)
        local batch_service = new_service()
        local batch_trace = install_script(t, {
            {
                kind = "tool",
                calls = { tool_list_call(), enable_call() },
            },
        })
        local batch_result = tool_sequence.run(
            batch_service, { messages = {} })
        t:assert_false(batch_result.ok)
        t:assert_true(batch_result.error.can_continue)
        t:assert_contains(batch_result.error.message, "exactly one call")
        t:assert_equal(0, batch_trace.side_effects)
        t:assert_equal(0, batch_result.tool_calls)

        local invalid_calls = {
            call("get_tool_list", { unexpected = true }),
            call("set_tool_enabled", {
                server = "fixture.weather",
            }),
            call("set_tool_enabled", {
                server = "fixture.weather",
                tool = "weather",
                extra = "not allowed",
            }),
            call("set_tool_disabled", {
                server = " ",
                tool = "weather",
            }),
            call("set_tool_disabled", {
                server = "fixture.weather",
                tool = "",
            }),
        }
        for _, invalid_call in ipairs(invalid_calls) do
            local service = new_service()
            local trace = install_script(t, {
                { kind = "tool", calls = { invalid_call } },
            })
            local result = tool_sequence.run(service, { messages = {} })
            t:assert_false(result.ok)
            t:assert_true(result.error.can_continue)
            t:assert_contains(result.error.message, "invalid arguments")
            t:assert_equal(0, trace.side_effects)
            t:assert_equal(0, result.tool_calls)
        end
    end)

    harness:test("unit", "Tool Search rejects an incompatible manager ABI before execution", function(t)
        local module_name = "oasis.local.tool.state"
        local original_state = package.loaded[module_name]
        t:on_cleanup(function()
            package.loaded[module_name] = original_state
        end)
        package.loaded[module_name] = {
            TOOL_SEARCH_ABI = 0,
            list = function() end,
            set_enabled = function() end,
            is_control_tool = function() end,
        }

        local service = new_service()
        local trace = install_script(t, {
            { kind = "tool", calls = { tool_list_call() } },
        })
        local result = tool_sequence.run(service, { messages = {} })
        t:assert_false(result.ok)
        t:assert_true(result.error.can_continue)
        t:assert_contains(result.error.message, "compatible oasis-mod-tool")
        t:assert_contains(result.error.detail, "r11")
        t:assert_equal(0, trace.side_effects)
        t:assert_equal(0, result.tool_calls)
    end)

    harness:test("unit", "Tool Search requires an exact manager registry binding", function(t)
        local service = new_service()
        local trace = install_script(t, {
            {
                kind = "tool",
                calls = { tool_list_call() },
                registry_sections = {
                    {
                        [".name"] = "wrong-manager",
                        server = "third.party.manager",
                        name = "get_tool_list",
                        enable = "1",
                        conflict = "0",
                    },
                },
            },
        })

        local result = tool_sequence.run(service, { messages = {} })
        t:assert_false(result.ok)
        t:assert_true(result.error.can_continue)
        t:assert_contains(result.error.detail, "uniquely bound")
        t:assert_equal(0, trace.side_effects)
        t:assert_equal(0, result.tool_calls)
    end)

    harness:test("unit", "repeated management operations are rejected before retry", function(t)
        local service = new_service()
        local trace = install_script(t, {
            { kind = "tool", calls = { tool_list_call() } },
            { kind = "tool", calls = { tool_list_call() } },
        })

        local result = tool_sequence.run(service, { messages = {} })
        assert_failed(t, result)
        t:assert_contains(result.error.message, "repeated")
        t:assert_equal(2, trace.authorizations)
        t:assert_equal(1, trace.side_effects)
        t:assert_equal(1, result.tool_rounds)
        t:assert_equal(1, result.tool_calls)
        t:assert_equal(1, #service.handled_outputs)

        local canonical_service = new_service()
        local omitted = tool_list_call()
        omitted.arguments = nil
        omitted.tool_call_id = "call-list-omitted"
        local explicit = tool_list_call()
        explicit.tool_call_id = "call-list-explicit"
        local canonical_trace = install_script(t, {
            { kind = "tool", calls = { omitted } },
            { kind = "tool", calls = { explicit } },
        })
        local canonical_result = tool_sequence.run(
            canonical_service, { messages = {} })
        assert_failed(t, canonical_result)
        t:assert_contains(canonical_result.error.message, "repeated")
        t:assert_equal(1, canonical_trace.side_effects)
        t:assert_equal(1, canonical_result.tool_calls)
    end)

    harness:test("unit", "tool round call and AI budgets reject work before execution", function(t)
        local round_service = new_service()
        local round_trace = install_script(t, {
            { kind = "tool", calls = { tool_list_call() } },
            { kind = "tool", calls = { enable_call() } },
        })
        local round_result = tool_sequence.run(
            round_service,
            { messages = {} },
            { max_tool_rounds = 1 }
        )
        assert_failed(t, round_result)
        t:assert_equal(1, round_trace.side_effects)
        t:assert_equal(1, round_result.tool_rounds)

        local call_service = new_service()
        local call_trace = install_script(t, {
            {
                kind = "tool",
                calls = { tool_list_call(), enable_call() },
            },
        })
        local call_result = tool_sequence.run(
            call_service,
            { messages = {} },
            { max_tool_calls = 1 }
        )
        t:assert_false(call_result.ok)
        t:assert_type("table", call_result.error)
        t:assert_true(call_result.error.can_continue)
        t:assert_contains(call_result.error.message, "tool-call limit")
        t:assert_equal(0, call_trace.side_effects)
        t:assert_equal(0, call_result.tool_calls)

        local ai_service = new_service()
        local ai_trace = install_script(t, {
            { kind = "tool", calls = { normal_call() } },
        })
        local ai_result = tool_sequence.run(
            ai_service,
            { messages = {} },
            { max_ai_requests = 1 }
        )
        t:assert_false(ai_result.ok)
        t:assert_type("table", ai_result.error)
        t:assert_true(ai_result.error.can_continue)
        t:assert_equal(1, ai_result.turns)
        t:assert_equal(0, ai_trace.side_effects)
        t:assert_false(ai_trace.contexts[1].allow_followup_tools)
    end)

    harness:test("unit", "provider failures after tool execution are not retryable", function(t)
        local service = new_service()
        local provider_error = chat_error.build(service, {
            phase = "api_response",
            kind = "api_error",
            message = "Follow-up request failed.",
            can_continue = true,
        })
        install_script(t, {
            { kind = "tool", calls = { normal_call() } },
            { kind = "error", error = provider_error },
        })

        local result = tool_sequence.run(service, { messages = {} })
        assert_failed(t, result)
        t:assert_equal(provider_error, result.error)
        t:assert_false(provider_error.can_continue)
        t:assert_contains(provider_error.display, "Chat can continue: no")

        local initial_service = new_service()
        local initial_error = chat_error.build(initial_service, {
            phase = "api_response",
            kind = "api_error",
            message = "Initial request failed.",
            can_continue = true,
        })
        install_script(t, {
            { kind = "error", error = initial_error },
        })
        local initial_result = tool_sequence.run(
            initial_service, { messages = {} })
        t:assert_false(initial_result.ok)
        t:assert_true(initial_result.error.can_continue)
    end)

    harness:test("unit", "sequence context is restored after unexpected failures", function(t)
        local old_context = { sentinel = "context" }
        local service = new_service({
            original_context = old_context,
            original_agent_mode = "legacy-mode",
        })
        install_script(t, {
            { kind = "throw", message = "provider crashed" },
        })

        local result = tool_sequence.run(service, { messages = {} })
        t:assert_false(result.ok)
        t:assert_type("table", result.error)
        t:assert_true(result.error.can_continue)
        t:assert_equal(old_context, service._tool_sequence_context)
        t:assert_equal("legacy-mode", service._agent_mode)
        t:assert_nil(service.provider_context)
        t:assert_equal(1, service.context_clear_calls)
    end)

    harness:test("unit", "confirmation continues in core mode and stops in agent mode", function(t)
        local confirmation_output = {
            status = "OK",
            reboot = true,
            user_only = "Restart the router?",
        }

        local core_service = new_service()
        install_script(t, {
            {
                kind = "tool",
                calls = { normal_call(confirmation_output) },
                reboot = true,
            },
            { kind = "final", message = "The restart is ready for confirmation." },
        })
        local core_result = tool_sequence.run(
            core_service, { messages = {} })
        t:assert_true(core_result.ok)
        t:assert_equal(2, core_result.turns)
        t:assert_equal("The restart is ready for confirmation.", core_result.message)
        local aggregate = decode(core_result.tool_info)
        t:assert_true(aggregate.reboot)

        local agent_service = new_service()
        local agent_trace = install_script(t, {
            {
                kind = "tool",
                calls = { normal_call(confirmation_output) },
                reboot = true,
            },
        })
        local agent_result = tool_sequence.run(
            agent_service,
            { messages = {} },
            { stop_on_confirmation = true }
        )
        assert_failed(t, agent_result)
        t:assert_equal("NEED_CONFIRMATION", agent_result.state)
        t:assert_true(agent_result.confirmation.reboot)
        t:assert_equal("Restart the router?", agent_result.message)
        t:assert_equal(1, agent_trace.requests)
    end)

    harness:test("unit", "normal tool domain errors are returned to the model", function(t)
        local service = new_service()
        local trace = install_script(t, {
            {
                kind = "tool",
                calls = { normal_call({
                    status = "NG",
                    error = "Weather station is unavailable",
                }) },
            },
            { kind = "final", message = "The weather station is unavailable." },
        })

        local result = tool_sequence.run(service, { messages = {} })
        t:assert_true(result.ok)
        t:assert_equal(2, trace.requests)
        t:assert_equal(1, trace.side_effects)
        t:assert_equal(1, #service.handled_outputs)
        t:assert_false(trace.contexts[2].allow_followup_tools)
        t:assert_equal("The weather station is unavailable.", result.message)
        local aggregate = decode(result.tool_info)
        t:assert_equal("Weather station is unavailable",
            aggregate.tool_outputs[1].output.error)
    end)

    harness:test("unit", "authorized and returned tool batches must match exactly", function(t)
        local service = new_service()
        local returned = normal_call()
        returned.arguments = { city = "Osaka" }
        local trace = install_script(t, {
            {
                kind = "tool",
                calls = { normal_call() },
                return_calls = { returned },
            },
        })

        local result = tool_sequence.run(service, { messages = {} })
        assert_failed(t, result)
        t:assert_contains(result.error.message, "did not match")
        t:assert_equal(1, trace.authorizations)
        t:assert_equal(1, trace.side_effects)
        t:assert_equal(0, result.tool_calls)
        t:assert_equal(0, #service.handled_outputs)

        local unauthorized_service = new_service()
        local unauthorized_trace = install_script(t, {
            {
                kind = "tool",
                calls = { normal_call() },
                skip_authorization = true,
            },
        })
        local unauthorized = tool_sequence.run(
            unauthorized_service, { messages = {} })
        assert_failed(t, unauthorized)
        t:assert_contains(unauthorized.error.message, "without sequence authorization")
        t:assert_equal(0, unauthorized_trace.authorizations)
        t:assert_equal(1, unauthorized_trace.side_effects)
    end)

    harness:test("unit", "all Tool Search results require an exact OK status", function(t)
        local service = new_service()
        local missing_status = tool_list_call()
        missing_status.output.status = nil
        install_script(t, {
            { kind = "tool", calls = { missing_status } },
        })

        local result = tool_sequence.run(service, { messages = {} })
        assert_failed(t, result)
        t:assert_contains(result.error.message, "management operation")
        t:assert_equal(1, result.tool_rounds)
        t:assert_equal(1, result.tool_calls)
        t:assert_equal(0, #service.handled_outputs)
    end)

    harness:test("unit", "service lifecycle hook failures stop before an AI request", function(t)
        local context_service = new_service({ context_result = false })
        local context_trace = install_script(t, {
            { kind = "final", message = "must not run" },
        })
        local context_result = tool_sequence.run(
            context_service, { messages = {} })
        t:assert_false(context_result.ok)
        t:assert_true(context_result.error.can_continue)
        t:assert_contains(context_result.error.message, "configure")
        t:assert_equal(1, context_service.begin_calls)
        t:assert_equal(0, context_trace.requests)

        local begin_service = new_service({ begin_result = false })
        local begin_trace = install_script(t, {
            { kind = "final", message = "must not run" },
        })
        local begin_result = tool_sequence.run(begin_service, { messages = {} })
        t:assert_false(begin_result.ok)
        t:assert_true(begin_result.error.can_continue)
        t:assert_contains(begin_result.error.message, "initialize")
        t:assert_equal(1, begin_service.begin_calls)
        t:assert_equal(0, begin_trace.requests)
    end)
end

return M
