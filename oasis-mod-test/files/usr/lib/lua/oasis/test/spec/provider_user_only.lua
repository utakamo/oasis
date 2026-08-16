local jsonc = require("luci.jsonc")

local M = {}
local SENTINEL = "OASIS_PRIVATE_SENTINEL"

local function disable_debug_logging()
    local logger = require("oasis.chat.debug")
    logger.disabled = true
end

local function raw_output()
    return jsonc.stringify({
        result = "ok",
        request = "shown",
        user_only = SENTINEL,
    }, false)
end

local function tool_info(call_id)
    return jsonc.stringify({
        tool_outputs = {
            {
                tool_call_id = call_id,
                name = "wifi_scan",
                output = raw_output(),
            },
        },
    }, false)
end

local function first_tool_content(t, chat, label)
    for _, message in ipairs(chat.messages or {}) do
        if message.role == "tool" then
            return message.content
        end
    end
    t:fail(label .. ": no unified tool message was added")
end

local function assert_ai_output(t, output, label)
    t:assert_type("string", output, label)
    t:assert_not_contains(output, SENTINEL,
        label .. ": user_only value reached AI state")
    local parsed = jsonc.parse(output)
    t:assert_type("table", parsed, label)
    t:assert_nil(parsed.user_only, label .. ": reserved field remained")
    t:assert_equal("ok", parsed.result, label)
    t:assert_equal("shown", parsed.request, label)
end

function M.register(harness)
    harness:test("provider", "OpenAI and OpenRouter continuation excludes user_only", function(t)
        disable_debug_logging()
        local service = require("oasis.chat.service.openai")
        service.cfg = {
            service = "OpenAI",
            model = "fixture-model",
            function_calling = "0",
            show_thinking = "0",
        }
        service.format = "chat"
        service._agent_mode = nil
        service._reboot_required = false
        local chat = { model = "fixture-model", messages = {} }

        t:assert_true(service:handle_tool_output(
            tool_info("openai-call"), chat))
        assert_ai_output(t,
            first_tool_content(t, chat, "OpenAI Chat Completions"),
            "OpenAI Chat Completions")

        local request_body = service:convert_schema(chat)
        t:assert_not_contains(request_body, SENTINEL,
            "OpenAI/OpenRouter outbound request")
        t:assert_not_contains(request_body, "user_only",
            "OpenAI/OpenRouter outbound request")
    end)

    harness:test("provider", "Ollama continuation excludes user_only", function(t)
        disable_debug_logging()
        local service = require("oasis.chat.service.ollama")
        service._completed_tool_message = {
            role = "assistant",
            content = "",
            tool_calls = {
                {
                    id = "ollama-call",
                    type = "function",
                    ["function"] = {
                        name = "wifi_scan",
                        arguments = {},
                    },
                },
            },
        }
        service._reboot_required = false
        local chat = { messages = {} }

        t:assert_true(service:handle_tool_output(
            tool_info("ollama-call"), chat))
        assert_ai_output(t,
            first_tool_content(t, chat, "Ollama"),
            "Ollama")
    end)

    harness:test("provider", "Anthropic pending continuation excludes user_only", function(t)
        disable_debug_logging()
        local service = require("oasis.chat.service.anthropic")
        service._tool_output_handled = false
        service._completed_tool_calls = {
            {
                id = "anthropic-call",
                name = "wifi_scan",
                input = {},
            },
        }
        service._completed_provider_content = {}
        service._pending_provider_messages = {}
        service._pending_tool_input_json_by_id = {}
        service._answer_text = ""
        local chat = { messages = {} }

        t:assert_true(service:handle_tool_output(
            tool_info("anthropic-call"), chat))
        assert_ai_output(t,
            service._pending_provider_messages[2].content[1].content,
            "Anthropic provider continuation")
        assert_ai_output(t,
            first_tool_content(t, chat, "Anthropic unified history"),
            "Anthropic unified history")
    end)

    harness:test("provider", "Gemini raw continuation excludes user_only", function(t)
        disable_debug_logging()
        local service = require("oasis.chat.service.gemini")
        service._tool_output_handled = false
        service._completed_tool_calls = {
            {
                id = "gemini-call",
                name = "wifi_scan",
                args = {},
            },
        }
        service._completed_provider_content = { role = "model", parts = {} }
        service._completed_provider_raw_content =
            '{"role":"model","parts":[]}'
        service._pending_provider_contents = {}
        service._pending_provider_raw_contents = {}
        service._pending_provider_bytes = 0
        service._answer_text = ""
        local chat = { messages = {} }

        t:assert_true(service:handle_tool_output(
            tool_info("gemini-call"), chat))
        local raw_pending = service._pending_provider_raw_contents[2]
        t:assert_not_contains(raw_pending, SENTINEL,
            "Gemini provider continuation")
        t:assert_not_contains(raw_pending, "user_only",
            "Gemini provider continuation")
        assert_ai_output(t,
            first_tool_content(t, chat, "Gemini unified history"),
            "Gemini unified history")
    end)

    harness:test("provider", "OpenAI Responses pending continuation excludes user_only", function(t)
        disable_debug_logging()
        local service = require("oasis.chat.service.openai_responses")
        service._function_call_order = {
            { call_id = "responses-call", name = "wifi_scan" },
        }
        service._completed_response_output = {}
        service._completed_tool_message = {
            role = "assistant",
            content = "",
            tool_calls = {
                {
                    id = "responses-call",
                    type = "function",
                    ["function"] = {
                        name = "wifi_scan",
                        arguments = "{}",
                    },
                },
            },
        }
        service._pending_provider_items = {}
        local chat = { messages = {} }

        t:assert_true(service:handle_tool_output(
            tool_info("responses-call"), chat))
        assert_ai_output(t,
            service._pending_provider_items[1].output,
            "OpenAI Responses provider continuation")
        assert_ai_output(t,
            first_tool_content(t, chat, "OpenAI Responses unified history"),
            "OpenAI Responses unified history")
    end)

    harness:test("provider", "provider handlers reject malformed tool output", function(t)
        disable_debug_logging()
        local malformed = jsonc.stringify({
            tool_outputs = {
                {
                    tool_call_id = "bad-call",
                    name = "wifi_scan",
                    output = '{"result":"ok","user_only":"unterminated"',
                },
            },
        }, false)

        local openai = require("oasis.chat.service.openai")
        local chat = { messages = {} }
        t:assert_false(openai:handle_tool_output(malformed, chat))
        t:assert_equal(0, #chat.messages)

        local responses = require("oasis.chat.service.openai_responses")
        responses._function_call_order = {
            { call_id = "bad-call", name = "wifi_scan" },
        }
        responses._completed_response_output = {}
        responses._completed_tool_message = {
            role = "assistant",
            content = "",
            tool_calls = {
                {
                    id = "bad-call",
                    type = "function",
                    ["function"] = {
                        name = "wifi_scan",
                        arguments = "{}",
                    },
                },
            },
        }
        responses._pending_provider_items = {}
        chat = { messages = {} }
        t:assert_false(responses:handle_tool_output(malformed, chat))
        t:assert_equal(0, #chat.messages)
        t:assert_equal(0, #responses._pending_provider_items)
    end)
end

return M
