local jsonc = require("luci.jsonc")

local M = {}

local ADAPTER_MODULES = {
    "oasis.chat.function.calling.openai",
    "oasis.chat.function.calling.ollama",
    "oasis.chat.function.calling.openai_responses",
    "oasis.chat.function.calling.anthropic",
    "oasis.chat.function.calling.gemini",
}

local function replace_loaded_modules(t, replacements, unloaded)
    local touched = {}
    local original = {}

    local function save(name)
        if touched[name] then
            return
        end
        touched[name] = true
        original[name] = package.loaded[name]
    end

    for name, value in pairs(replacements or {}) do
        save(name)
        package.loaded[name] = value
    end
    for _, name in ipairs(unloaded or {}) do
        save(name)
        package.loaded[name] = nil
    end

    t:on_cleanup(function()
        for name in pairs(touched) do
            package.loaded[name] = original[name]
        end
    end)
end

local function schema_entry(name)
    return {
        name = name,
        description = name .. " fixture",
        parameters = {
            type = "object",
            properties = {},
        },
    }
end

local function install_adapter_fixture(t)
    local fixture = {
        events = {},
        exec_calls = {},
        schema = {},
        schema_calls = 0,
    }

    local client = {}
    client.exec_server_tool = function(format, name, arguments, mode_token)
        fixture.events[#fixture.events + 1] = "exec:" .. tostring(name)
        fixture.exec_calls[#fixture.exec_calls + 1] = {
            format = format,
            name = name,
            arguments = arguments,
            mode_token = mode_token,
        }
        return { result = "ok", name = name }
    end
    client.get_function_call_schema = function()
        fixture.schema_calls = fixture.schema_calls + 1
        return fixture.schema
    end

    replace_loaded_modules(t, {
        ["luci.model.uci"] = {
            cursor = function()
                return {
                    get_all = function() return {} end,
                    get_bool = function()
                        return true
                    end,
                }
            end,
        },
        ["oasis.local.tool.client"] = client,
        ["oasis.chat.debug"] = {
            disabled = true,
            log = function()
            end,
        },
    }, ADAPTER_MODULES)

    return fixture
end

local function reset_activity(fixture)
    fixture.events = {}
    fixture.exec_calls = {}
end

local function new_service(provider, fixture, authorize)
    local service = {
        cfg = {
            service = provider,
            model = "fixture-model",
            function_calling = "1",
        },
        format = "chat",
        _request_tools_enabled = true,
        _request_tool_names = { wifi_scan = true },
        processed_tool_call_ids = {},
        _processed_tool_results = {},
    }

    if provider == "Anthropic" then
        service._request_tool_choice = "auto"
    elseif provider == "Gemini" then
        service._request_tool_choice = "AUTO"
    end

    service.get_config = function(self)
        return self.cfg
    end
    service.get_format = function(self)
        return self.format
    end
    service._tool_sequence_context = {
        active = true,
        remaining_tool_calls = 8,
        authorize_tool_batch = function(batch)
            fixture.events[#fixture.events + 1] = "authorize"
            fixture.authorization_calls =
                (fixture.authorization_calls or 0) + 1
            fixture.authorized_batch = batch
            return authorize(batch)
        end,
    }
    return service
end

local function provider_cases()
    return {
        {
            name = "OpenAI Chat Completions",
            provider = "OpenAI",
            module = "oasis.chat.function.calling.openai",
            make_call = function(id, name, arguments)
                return {
                    id = id,
                    type = "function",
                    ["function"] = {
                        name = name,
                        arguments = arguments,
                    },
                }
            end,
            invoke = function(adapter, service, calls)
                return adapter.process(service, {
                    role = "assistant",
                    content = "",
                    tool_calls = calls,
                })
            end,
        },
        {
            name = "Ollama",
            provider = "Ollama",
            module = "oasis.chat.function.calling.ollama",
            make_call = function(id, name, arguments)
                return {
                    id = id,
                    type = "function",
                    ["function"] = {
                        name = name,
                        arguments = arguments,
                    },
                }
            end,
            invoke = function(adapter, service, calls)
                return adapter.process(service, {
                    role = "assistant",
                    content = "",
                    tool_calls = calls,
                })
            end,
        },
        {
            name = "OpenAI Responses",
            provider = "OpenAI",
            module = "oasis.chat.function.calling.openai_responses",
            make_call = function(id, name, arguments)
                return {
                    call_id = id,
                    name = name,
                    arguments = require("oasis.chat.function.calling.policy")
                        .stringify_object(arguments),
                }
            end,
            invoke = function(adapter, service, calls)
                return adapter.process(service, calls)
            end,
        },
        {
            name = "Anthropic",
            provider = "Anthropic",
            module = "oasis.chat.function.calling.anthropic",
            make_call = function(id, name, arguments)
                return {
                    id = id,
                    name = name,
                    input = arguments,
                }
            end,
            invoke = function(adapter, service, calls)
                return adapter.process(service, calls)
            end,
        },
        {
            name = "Gemini",
            provider = "Gemini",
            module = "oasis.chat.function.calling.gemini",
            make_call = function(id, name, arguments)
                return {
                    id = id,
                    provider_id = "provider-" .. id,
                    name = name,
                    args = arguments,
                }
            end,
            invoke = function(adapter, service, calls)
                return adapter.process(service, calls)
            end,
        },
    }
end

local function valid_batch(case)
    return {
        case.make_call(case.name .. "-1", "wifi_scan", { z = 2, a = 1 }),
        case.make_call(case.name .. "-2", "wifi_scan", { z = 4, a = 3 }),
    }
end

local function save_fields(t, object, fields)
    local values = {}
    for _, field in ipairs(fields) do
        values[field] = object[field]
    end
    t:on_cleanup(function()
        for _, field in ipairs(fields) do
            object[field] = values[field]
        end
    end)
end

function M.register(harness)
    harness:test("provider", "provider adapters validate and authorize a complete batch before execution", function(t)
        local fixture = install_adapter_fixture(t)

        for _, case in ipairs(provider_cases()) do
            local adapter = require(case.module)

            reset_activity(fixture)
            fixture.authorization_calls = 0
            fixture.authorized_batch = nil
            local validation_service = new_service(
                case.provider, fixture, function()
                    return true
                end)
            local invalid_calls = {
                case.make_call(case.name .. "-valid", "wifi_scan",
                    { z = 2, a = 1 }),
                case.make_call(case.name .. "-invalid", nil,
                    { z = 4, a = 3 }),
            }
            local _, _, _, invalid_used, invalid_error =
                case.invoke(adapter, validation_service, invalid_calls)
            t:assert_false(invalid_used, case.name .. " invalid batch")
            t:assert_not_nil(invalid_error, case.name .. " invalid batch")
            t:assert_true(invalid_error.can_continue,
                case.name .. " pre-execution validation retryability")
            t:assert_equal(0, fixture.authorization_calls,
                case.name .. " authorized a partially validated batch")
            t:assert_equal(0, #fixture.exec_calls,
                case.name .. " executed before validating the complete batch")

            if case.module == "oasis.chat.function.calling.openai"
                or case.module == "oasis.chat.function.calling.ollama" then
                reset_activity(fixture)
                fixture.authorization_calls = 0
                fixture.authorized_batch = nil
                local sparse_service = new_service(
                    case.provider, fixture, function()
                        return true
                    end)
                local sparse_calls = {
                    [1] = case.make_call(case.name .. "-sparse-1",
                        "wifi_scan", { z = 2, a = 1 }),
                    [3] = case.make_call(case.name .. "-sparse-3",
                        "wifi_scan", { z = 4, a = 3 }),
                }
                local _, _, _, sparse_used, sparse_error =
                    case.invoke(adapter, sparse_service, sparse_calls)
                t:assert_false(sparse_used, case.name .. " sparse batch")
                t:assert_not_nil(sparse_error,
                    case.name .. " sparse batch error")
                t:assert_true(sparse_error.can_continue,
                    case.name .. " sparse batch retryability")
                t:assert_equal(0, fixture.authorization_calls,
                    case.name .. " authorized a sparse batch")
                t:assert_equal(0, #fixture.exec_calls,
                    case.name .. " executed a sparse batch")
            end

            reset_activity(fixture)
            fixture.authorization_calls = 0
            fixture.authorized_batch = nil
            local denied = { kind = "fixture_denied", provider = case.name }
            local denial_service = new_service(
                case.provider, fixture, function()
                    return false, denied
                end)
            local _, _, _, denied_used, denied_error =
                case.invoke(adapter, denial_service, valid_batch(case))
            t:assert_false(denied_used, case.name .. " denied batch")
            t:assert_equal(denied, denied_error,
                case.name .. " did not preserve the authorization error")
            t:assert_equal(1, fixture.authorization_calls,
                case.name .. " authorization count")
            t:assert_equal(0, #fixture.exec_calls,
                case.name .. " executed a rejected batch")
            t:assert_equal("authorize", fixture.events[1],
                case.name .. " authorization order")
            t:assert_equal(2, #fixture.authorized_batch,
                case.name .. " authorization batch size")
            t:assert_deep_equal({ a = 1, z = 2 },
                jsonc.parse(fixture.authorized_batch[1].arguments),
                case.name .. " first authorization arguments")
            t:assert_deep_equal({ a = 3, z = 4 },
                jsonc.parse(fixture.authorized_batch[2].arguments),
                case.name .. " second authorization arguments")
        end
    end)

    harness:test("provider", "provider adapters preserve arguments after authorized execution", function(t)
        local fixture = install_adapter_fixture(t)

        for _, case in ipairs(provider_cases()) do
            reset_activity(fixture)
            fixture.authorization_calls = 0
            fixture.authorized_batch = nil
            local service = new_service(
                case.provider, fixture, function()
                    return true
                end)
            service._tool_mode_token = "1:42"
            local adapter = require(case.module)
            local _, response, _, used, process_error =
                case.invoke(adapter, service, valid_batch(case))

            t:assert_true(used, case.name .. " execution result")
            t:assert_nil(process_error, case.name .. " execution error")
            t:assert_equal(1, fixture.authorization_calls,
                case.name .. " authorization count")
            t:assert_equal(2, #fixture.exec_calls,
                case.name .. " execution count")
            for _, executed in ipairs(fixture.exec_calls) do
                t:assert_equal("1:42", executed.mode_token,
                    case.name .. " omitted the dispatch mode guard")
            end
            t:assert_equal("authorize", fixture.events[1],
                case.name .. " authorization must precede execution")
            t:assert_equal("exec:wifi_scan", fixture.events[2],
                case.name .. " first execution order")
            t:assert_equal("exec:wifi_scan", fixture.events[3],
                case.name .. " second execution order")

            local parsed = jsonc.parse(response)
            t:assert_type("table", parsed, case.name .. " tool info")
            t:assert_equal(2, #(parsed.tool_outputs or {}),
                case.name .. " tool output count")
            t:assert_deep_equal({ a = 1, z = 2 },
                jsonc.parse(parsed.tool_outputs[1].arguments),
                case.name .. " first tool-info arguments")
            t:assert_deep_equal({ a = 3, z = 4 },
                jsonc.parse(parsed.tool_outputs[2].arguments),
                case.name .. " second tool-info arguments")
        end
    end)

    harness:test("provider", "argument arrays preserve empty arrays and null holes in every adapter", function(t)
        local fixture = install_adapter_fixture(t)
        for _, case in ipairs(provider_cases()) do
            for _, raw in ipairs({
                '{"items":[]}',
                '{"items":[1,null,3]}',
                '{"items":[null,false,[],{"nested":[2,null,4]}]}',
            }) do
                reset_activity(fixture)
                local service = new_service(case.provider, fixture, function() return true end)
                local args = jsonc.parse(raw)
                local expected = jsonc.stringify(args, false)
                local adapter = require(case.module)
                local _, response, speaker, used, err = case.invoke(adapter, service, {
                    case.make_call("array-fixture", "wifi_scan", args),
                })
                t:assert_true(used, case.name .. " " .. raw)
                t:assert_nil(err, case.name .. " valid argument rejected")
                t:assert_equal(1, #fixture.exec_calls)
                t:assert_equal(expected, jsonc.stringify(fixture.exec_calls[1].arguments, false))
                t:assert_equal(expected, fixture.authorized_batch[1].arguments)
                t:assert_equal(expected, jsonc.parse(response).tool_outputs[1].arguments)
                if speaker and speaker.tool_calls then
                    local fn = speaker.tool_calls[1]["function"]
                    -- Ollama's native speaker keeps table arguments.
                    local history_args = type(fn.arguments) == "table"
                        and jsonc.stringify(fn.arguments, false) or fn.arguments
                    t:assert_equal(expected, history_args)
                end
                t:assert_equal(expected, jsonc.stringify(args, false), "arguments mutated")
            end
        end
    end)

    harness:test("provider", "argument identity ignores key order but distinguishes array contents", function(t)
        local fixture = install_adapter_fixture(t)
        local policy = require("oasis.chat.function.calling.policy")
        local first = jsonc.parse('{"z":[1,null,3],"a":[]}')
        local reordered = jsonc.parse('{"a":[],"z":[1,null,3]}')
        t:assert_equal('{"a":[],"z":[1,null,3]}', policy.canonical_object(first))
        t:assert_equal(policy.canonical_object(first), policy.canonical_object(reordered))
        t:assert_nil(policy.stringify_object({ items = { [1] = 1, invalid = 2 } }))
        local cyclic = {}; cyclic.self = cyclic
        t:assert_nil(policy.stringify_object(cyclic))
        t:assert_nil(policy.stringify_object({ bad = math.huge }))
        t:assert_nil(policy.stringify_object({ bad = function() end }))
        t:assert_equal("{}", policy.stringify_object({}))
        for _, case in ipairs(provider_cases()) do
            reset_activity(fixture)
            local service = new_service(case.provider, fixture, function() return true end)
            local adapter = require(case.module)
            for _, args in ipairs({ first, reordered }) do
                local _, _, _, used, err = case.invoke(adapter, service, {
                    case.make_call("same-id", "wifi_scan", args),
                })
                t:assert_true(used, case.name)
                t:assert_nil(err, case.name)
            end
            t:assert_equal(1, #fixture.exec_calls, case.name .. " repeated a cached execution")
            local _, _, _, used, err = case.invoke(adapter, service, {
                case.make_call("same-id", "wifi_scan", { z = { 1, 2, 3 }, a = {} }),
            })
            t:assert_false(used, case.name)
            t:assert_not_nil(err, case.name .. " accepted a changed call ID")
            t:assert_equal(1, #fixture.exec_calls)
        end
    end)

    harness:test("provider", "string arguments and real adapters cross the sequence identity barrier", function(t)
        local fixture = install_adapter_fixture(t)
        local transfer = require("oasis.chat.transfer")
        local sequence = require("oasis.chat.tool_sequence")
        local original_transfer = transfer.chat_with_ai
        t:on_cleanup(function() transfer.chat_with_ai = original_transfer end)
        for _, case in ipairs(provider_cases()) do
            reset_activity(fixture)
            local requests = 0
            local service = new_service(case.provider, fixture, function()
                error("The runner must install its own authorizer")
            end)
            service.handle_tool_output = function() return true end
            service.get_config = function(self) return self.cfg end
            local raw = '{"items":[[],1,null,3]}'
            local native_call = case.make_call("sequence-array", "wifi_scan", jsonc.parse(raw))
            if case.provider == "OpenAI" or case.provider == "Ollama" then
                if native_call["function"] then
                    native_call["function"].arguments = raw
                else
                    native_call.arguments = raw
                end
            elseif case.provider == "Anthropic" then
                native_call.input_json = raw
            end
            transfer.chat_with_ai = function(self)
                requests = requests + 1
                if requests == 2 then
                    t:assert_false(self._tool_sequence_context.allow_followup_tools)
                    return nil, "done", false, nil
                end
                local plain, info, _, used, err = case.invoke(
                    require(case.module), self, { native_call })
                return info, plain, used, err
            end
            local result = sequence.run(service, { messages = {} })
            t:assert_true(result.ok, case.name .. " " .. tostring(result.message))
            t:assert_equal(2, requests, case.name)
            t:assert_equal(1, #fixture.exec_calls, case.name)
            t:assert_equal(raw, jsonc.stringify(fixture.exec_calls[1].arguments, false), case.name)
            t:assert_equal(raw, jsonc.parse(result.tool_info).tool_outputs[1].arguments, case.name)
        end
    end)

    harness:test("provider", "Anthropic and Gemini refresh tool schemas only after management rounds", function(t)
        local fixture = install_adapter_fixture(t)

        fixture.schema = { schema_entry("get_tool_list") }
        fixture.schema_calls = 0
        local anthropic = require(
            "oasis.chat.function.calling.anthropic")
        local anthropic_service = new_service(
            "Anthropic", fixture, function()
                return true
            end)
        local initial_anthropic = anthropic.inject_schema(
            anthropic_service, {}, {})
        t:assert_equal("get_tool_list", initial_anthropic.tools[1].name)
        t:assert_equal(1, fixture.schema_calls)

        local anthropic_pending = {
            {
                role = "assistant",
                content = {
                    { type = "thinking", signature = "anthropic-signature" },
                },
            },
        }
        local anthropic_raw_inputs = {
            ["anthropic-call"] = '{"preserve":"raw-input"}',
        }
        anthropic_service._pending_provider_messages = anthropic_pending
        anthropic_service._pending_tool_input_json_by_id =
            anthropic_raw_inputs
        fixture.schema = {
            schema_entry("get_tool_list"),
            schema_entry("wifi_scan"),
        }

        local ordinary_anthropic = anthropic.inject_schema(
            anthropic_service, {}, { followup = true })
        t:assert_equal(1, #ordinary_anthropic.tools)
        t:assert_equal("get_tool_list", ordinary_anthropic.tools[1].name)
        t:assert_equal(1, fixture.schema_calls,
            "Anthropic ordinary continuation re-read the registry")
        t:assert_true(anthropic_service._pending_provider_messages
            == anthropic_pending)
        t:assert_true(anthropic_service._pending_tool_input_json_by_id
            == anthropic_raw_inputs)

        local refreshed_anthropic = anthropic.inject_schema(
            anthropic_service, {}, {
                followup = true,
                refresh_tool_registry = true,
            })
        t:assert_equal(2, #refreshed_anthropic.tools)
        t:assert_equal("wifi_scan", refreshed_anthropic.tools[2].name)
        t:assert_equal(2, fixture.schema_calls,
            "Anthropic management continuation did not refresh the registry")
        t:assert_true(anthropic_service._pending_provider_messages
            == anthropic_pending)
        t:assert_true(anthropic_service._pending_tool_input_json_by_id
            == anthropic_raw_inputs)

        fixture.schema = { schema_entry("get_tool_list") }
        fixture.schema_calls = 0
        local gemini = require("oasis.chat.function.calling.gemini")
        local gemini_service = new_service(
            "Gemini", fixture, function()
                return true
            end)
        local initial_gemini = gemini.inject_schema(
            gemini_service, {}, {})
        local initial_declarations =
            initial_gemini.tools[1].functionDeclarations
        t:assert_equal("get_tool_list", initial_declarations[1].name)
        t:assert_equal(1, fixture.schema_calls)

        local gemini_pending = {
            {
                role = "model",
                parts = {
                    { thought = true, thoughtSignature = "gemini-signature" },
                },
            },
        }
        local gemini_pending_raw = {
            '{"role":"model","parts":[{"thoughtSignature":"raw"}]}',
        }
        gemini_service._pending_provider_contents = gemini_pending
        gemini_service._pending_provider_raw_contents = gemini_pending_raw
        gemini_service._pending_provider_bytes = #gemini_pending_raw[1]
        fixture.schema = {
            schema_entry("get_tool_list"),
            schema_entry("wifi_scan"),
        }

        local ordinary_gemini = gemini.inject_schema(
            gemini_service, {}, { followup = true })
        local ordinary_declarations =
            ordinary_gemini.tools[1].functionDeclarations
        t:assert_equal(1, #ordinary_declarations)
        t:assert_equal("get_tool_list", ordinary_declarations[1].name)
        t:assert_equal(1, fixture.schema_calls,
            "Gemini ordinary continuation re-read the registry")
        t:assert_true(gemini_service._pending_provider_contents
            == gemini_pending)
        t:assert_true(gemini_service._pending_provider_raw_contents
            == gemini_pending_raw)
        t:assert_equal(#gemini_pending_raw[1],
            gemini_service._pending_provider_bytes)

        local refreshed_gemini = gemini.inject_schema(
            gemini_service, {}, {
                followup = true,
                refresh_tool_registry = true,
            })
        local refreshed_declarations =
            refreshed_gemini.tools[1].functionDeclarations
        t:assert_equal(2, #refreshed_declarations)
        t:assert_equal("wifi_scan", refreshed_declarations[2].name)
        t:assert_equal(2, fixture.schema_calls,
            "Gemini management continuation did not refresh the registry")
        t:assert_true(gemini_service._pending_provider_contents
            == gemini_pending)
        t:assert_true(gemini_service._pending_provider_raw_contents
            == gemini_pending_raw)
        t:assert_equal(#gemini_pending_raw[1],
            gemini_service._pending_provider_bytes)
    end)

    harness:test("provider", "OpenAI Responses rejects null holes before tool authorization", function(t)
        local fixture = install_adapter_fixture(t)
        replace_loaded_modules(t, {}, {
            "oasis.chat.service.openai_responses",
        })

        local service = require("oasis.chat.service.openai_responses")
        service.cfg = {
            service = "OpenAI",
            model = "fixture-model",
            function_calling = "1",
        }
        service.format = "chat"
        service._request_tools_enabled = true
        service._request_tool_names = { wifi_scan = true }
        service:set_tool_sequence_context({
            active = true,
            remaining_tool_calls = 8,
            authorize_tool_batch = function()
                fixture.authorization_calls =
                    (fixture.authorization_calls or 0) + 1
                fixture.events[#fixture.events + 1] = "authorize"
                return true
            end,
        })
        fixture.authorization_calls = 0
        reset_activity(fixture)

        local payload = [[
{"status":"completed","output":[
  {"id":"item-1","type":"function_call","call_id":"call-1","name":"wifi_scan","arguments":"{}"},
  null,
  {"id":"item-3","type":"function_call","call_id":"call-3","name":"wifi_scan","arguments":"{}"}
]}
]]
        local decoded = jsonc.parse(payload)
        t:assert_nil(decoded.output[2],
            "fixture null must decode as an array hole")
        t:assert_type("table", decoded.output[3],
            "fixture must retain the item following the hole")

        local records, framing_error =
            service:frame_ai_response(payload, true)
        t:assert_nil(framing_error)
        t:assert_equal(1, #records)

        local response_error
        local tool_used = false
        for _, record in ipairs(records) do
            local _, _, _, used, err = service:recv_ai_msg(record)
            tool_used = tool_used or used == true
            response_error = err or response_error
        end
        -- Follow the normal success path only if response parsing incorrectly
        -- accepted the sparse authoritative output. This makes the fixture fail
        -- on the former behavior that executed the first call and ignored the
        -- call after the null hole.
        if not response_error then
            local _, _, _, used, err = service:finalize_ai_response()
            tool_used = tool_used or used == true
            response_error = err
        end

        t:assert_not_nil(response_error)
        t:assert_equal("response_parse", response_error.phase)
        t:assert_equal("parse_error", response_error.kind)
        t:assert_contains(response_error.detail, "dense array")
        t:assert_true(response_error.can_continue)
        t:assert_false(tool_used)
        t:assert_equal(0, fixture.authorization_calls,
            "sparse completed output reached authorization")
        t:assert_equal(0, #fixture.exec_calls,
            "sparse completed output reached tool execution")
        t:assert_false(service._tool_side_effects_committed,
            "sparse completed output marked a side effect")
        t:assert_equal(0, #(service._function_call_order or {}),
            "sparse completed output was partially merged")
    end)

    harness:test("provider", "Ollama finalization delegates the complete batch to its calling adapter", function(t)
        local adapter = require("oasis.chat.function.calling.ollama")
        local service = require("oasis.chat.service.ollama")
        local original_process = adapter.process
        local original_client = package.loaded["oasis.local.tool.client"]
        local process_calls = 0
        local received_message

        package.loaded["oasis.local.tool.client"] = {
            exec_server_tool = function()
                return { result = "fixture-only" }
            end,
        }
        adapter.process = function(self, message)
            process_calls = process_calls + 1
            received_message = message
            return "delegated", "delegated-json", {
                role = "assistant",
                content = "",
                tool_calls = message.tool_calls,
            }, true, nil
        end
        t:on_cleanup(function()
            adapter.process = original_process
            package.loaded["oasis.local.tool.client"] = original_client
        end)

        save_fields(t, service, {
            "_assistant_accumulator",
            "_tool_calls_finalized",
            "_completed_tool_message",
            "_collect_tool_stream",
            "cfg",
            "recv_raw_msg",
        })
        service.cfg = {
            endpoint = "http://fixture.invalid/api/chat",
            api_key = "",
        }
        local easy = {
            setopt_url = function()
            end,
            setopt_writefunction = function()
            end,
            setopt_httpheader = function()
            end,
            setopt_httppost = function()
            end,
            setopt_postfields = function()
            end,
        }
        service:prepare_post_to_server(
            easy,
            function()
            end,
            {},
            jsonc.stringify({ stream = true, messages = {} }, false)
        )
        t:assert_true(service._collect_tool_stream,
            "Ollama must collect unsolicited tool calls for rejection")

        local sparse_error = service:_accumulate_response_message({
            tool_calls = {
                [1] = {
                    id = "ollama-sparse-1",
                    ["function"] = {
                        name = "wifi_scan",
                        arguments = {},
                    },
                },
                [3] = {
                    id = "ollama-sparse-3",
                    ["function"] = {
                        name = "wifi_scan",
                        arguments = {},
                    },
                },
            },
        })
        t:assert_not_nil(sparse_error,
            "Ollama must reject sparse streamed tool-call batches")
        t:assert_equal(0, #(service._assistant_accumulator.tool_calls or {}),
            "Ollama must not retain a partial sparse batch")

        local accumulator = {
            role = "assistant",
            content = "",
            thinking = "",
            tool_calls = {
                {
                    id = "ollama-finalize-call",
                    type = "function",
                    ["function"] = {
                        name = "wifi_scan",
                        arguments = { interface = "wlan0" },
                    },
                },
            },
        }
        service._assistant_accumulator = accumulator
        service._tool_calls_finalized = false
        service._completed_tool_message = nil
        service.recv_raw_msg = { role = "assistant", message = "" }

        local plain, response, speaker, used, finalize_error =
            service:finalize_ai_response()
        t:assert_equal(1, process_calls)
        t:assert_equal(accumulator, received_message)
        t:assert_equal("delegated", plain)
        t:assert_equal("delegated-json", response)
        t:assert_true(used)
        t:assert_nil(finalize_error)
        t:assert_equal(speaker, service._completed_tool_message)
    end)

    harness:test("provider", "provider sequence startup resets turn-local execution caches", function(t)
        local services = {
            {
                name = "OpenAI Chat Completions",
                module = "oasis.chat.service.openai",
            },
            {
                name = "Ollama",
                module = "oasis.chat.service.ollama",
            },
            {
                name = "OpenAI Responses",
                module = "oasis.chat.service.openai_responses",
            },
            {
                name = "Anthropic",
                module = "oasis.chat.service.anthropic",
            },
            {
                name = "Gemini",
                module = "oasis.chat.service.gemini",
            },
        }
        local fields = {
            "processed_tool_call_ids",
            "_processed_tool_results",
            "_tool_side_effects_committed",
            "_request_tools_enabled",
            "_request_tool_names",
            "_reboot_required",
            "_pending_provider_items",
            "_pending_provider_messages",
            "_pending_tool_input_json_by_id",
            "_pending_provider_contents",
            "_pending_provider_raw_contents",
            "_pending_provider_bytes",
            "_active_tool_definitions",
            "chunk_all",
            "mark",
        }

        for _, case in ipairs(services) do
            local service = require(case.module)
            save_fields(t, service, fields)
            service.processed_tool_call_ids = { stale = "signature" }
            service._processed_tool_results = {
                stale = { output = "stale" },
            }
            service._tool_side_effects_committed = true
            service._request_tools_enabled = true
            service._request_tool_names = { stale = true }
            service._reboot_required = true
            if case.name == "OpenAI Chat Completions" then
                service.chunk_all = "partial-json"
                service.mark = { stale = true }
            end
            if case.name == "OpenAI Responses" then
                service._pending_provider_items = { { type = "stale" } }
            elseif case.name == "Anthropic" then
                service._pending_provider_messages = { { role = "assistant" } }
                service._pending_tool_input_json_by_id = { stale = "{}" }
                service._active_tool_definitions = { { name = "stale" } }
            elseif case.name == "Gemini" then
                service._pending_provider_contents = { { role = "model" } }
                service._pending_provider_raw_contents = { "stale" }
                service._pending_provider_bytes = 5
                service._active_tool_definitions = { { name = "stale" } }
            end

            t:assert_true(service:begin_tool_sequence(), case.name)
            t:assert_nil(next(service.processed_tool_call_ids),
                case.name .. " processed ID cache")
            t:assert_nil(next(service._processed_tool_results),
                case.name .. " processed result cache")
            t:assert_false(service._tool_side_effects_committed,
                case.name .. " side-effect marker")
            t:assert_false(service._request_tools_enabled,
                case.name .. " request tool flag")
            t:assert_nil(next(service._request_tool_names),
                case.name .. " request tool names")
            t:assert_true(service._reboot_required,
                case.name .. " reboot result must outlive the turn cache")
            if case.name == "OpenAI Chat Completions" then
                t:assert_equal("", service.chunk_all,
                    "OpenAI partial response bytes must not cross user turns")
                t:assert_nil(next(service.mark),
                    "OpenAI markdown state must not cross user turns")
            end
            if case.name == "OpenAI Responses" then
                t:assert_nil(service._pending_provider_items,
                    "Responses pending items must not cross user turns")
            elseif case.name == "Anthropic" then
                t:assert_equal(0, #service._pending_provider_messages,
                    "Anthropic pending messages must not cross user turns")
                t:assert_nil(next(service._pending_tool_input_json_by_id))
                t:assert_nil(service._active_tool_definitions)
            elseif case.name == "Gemini" then
                t:assert_equal(0, #service._pending_provider_contents,
                    "Gemini pending contents must not cross user turns")
                t:assert_equal(0, #service._pending_provider_raw_contents)
                t:assert_equal(0, service._pending_provider_bytes)
                t:assert_nil(service._active_tool_definitions)
            end
        end
    end)
end

return M
