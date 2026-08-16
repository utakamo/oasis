local jsonc = require("luci.jsonc")
local common = require("oasis.common")

local M = {}

local function disable_debug_logging()
    local logger = require("oasis.chat.debug")
    logger.disabled = true
end

local function capture_request(service, body)
    local captured = {}
    local easy = {
        setopt_url = function(_, value)
            captured.url = value
        end,
        setopt_writefunction = function(_, value)
            captured.callback = value
        end,
        setopt_httpheader = function(_, value)
            captured.headers = value
        end,
        setopt_httppost = function(_, value)
            captured.form = value
        end,
        setopt_postfields = function(_, value)
            captured.body = value
        end,
    }
    local callback = function()
        return true
    end
    local form = { fixture = true }
    service:prepare_post_to_server(easy, callback, form, body)
    captured.expected_callback = callback
    captured.expected_form = form
    return captured
end

local function has_header(headers, expected)
    for _, header in ipairs(headers or {}) do
        if header == expected then
            return true
        end
    end
    return false
end

local function assert_common_request(t, captured, expected)
    t:assert_equal(expected.url, captured.url, expected.name .. " URL")
    t:assert_equal(expected.body, captured.body, expected.name .. " body")
    t:assert_equal(captured.expected_callback, captured.callback,
        expected.name .. " callback")
    t:assert_equal(captured.expected_form, captured.form,
        expected.name .. " form")
    t:assert_true(has_header(captured.headers, "Content-Type: application/json"),
        expected.name .. " content type")
end

function M.register(harness)
    harness:test("provider", "provider transports build requests without network I/O", function(t)
        disable_debug_logging()
        local body = '{"fixture":true}'
        local cases = {
            {
                name = "OpenAI Chat Completions",
                module = "oasis.chat.service.openai",
                cfg = {
                    endpoint = "https://openai.invalid/v1/chat/completions",
                    api_key = "openai-secret",
                    function_calling = "0",
                },
                expected_url = "https://openai.invalid/v1/chat/completions",
                headers = {
                    "Authorization: Bearer openai-secret",
                },
            },
            {
                name = "OpenAI Responses",
                module = "oasis.chat.service.openai_responses",
                cfg = {
                    endpoint = "https://openai.invalid/v1/responses/",
                    api_key = "responses-secret",
                    function_calling = "0",
                },
                expected_url = "https://openai.invalid/v1/responses/",
                headers = {
                    "Accept: text/event-stream",
                    "Authorization: Bearer responses-secret",
                },
            },
            {
                name = "Anthropic",
                module = "oasis.chat.service.anthropic",
                cfg = {
                    endpoint = "https://anthropic.invalid/v1/messages",
                    api_key = "anthropic-secret",
                    function_calling = "0",
                },
                expected_url = "https://anthropic.invalid/v1/messages",
                headers = {
                    "Accept: text/event-stream",
                    "x-api-key: anthropic-secret",
                    "anthropic-version: 2023-06-01",
                },
            },
            {
                name = "Gemini",
                module = "oasis.chat.service.gemini",
                cfg = {
                    endpoint = "https://gemini.invalid/",
                    model = "gemini-fixture",
                    api_key = "gemini-secret",
                    function_calling = "0",
                },
                expected_url = "https://gemini.invalid/v1beta/models/"
                    .. "gemini-fixture:streamGenerateContent?alt=sse",
                headers = {
                    "Accept: text/event-stream",
                    "X-Goog-Api-Key: gemini-secret",
                },
            },
            {
                name = "Ollama",
                module = "oasis.chat.service.ollama",
                cfg = {
                    endpoint = "https://ollama.invalid/api/chat",
                    api_key = "ollama-secret",
                    function_calling = "0",
                },
                format = common.ai.format.output,
                expected_url = "https://ollama.invalid/api/chat",
                headers = {
                    "Authorization: Bearer ollama-secret",
                },
            },
            {
                name = "LM Studio",
                module = "oasis.chat.service.lmstudio",
                cfg = {
                    endpoint = "https://lmstudio.invalid/api/v1/chat/",
                    api_key = "lmstudio-secret",
                    function_calling = "0",
                },
                expected_url = "https://lmstudio.invalid/api/v1/chat/",
                headers = {
                    "Accept: text/event-stream",
                    "Authorization: Bearer lmstudio-secret",
                },
            },
        }

        for _, case in ipairs(cases) do
            local service = require(case.module)
            service.cfg = case.cfg
            service.format = case.format or common.ai.format.chat
            service._request_tools_enabled = false
            service._request_thinking = nil
            local captured = capture_request(service, body)
            assert_common_request(t, captured, {
                name = case.name,
                url = case.expected_url,
                body = body,
            })
            for _, header in ipairs(case.headers) do
                t:assert_true(has_header(captured.headers, header),
                    case.name .. " missing header: " .. header)
            end
        end
    end)

    harness:test("provider", "optional bearer headers are omitted for empty keys", function(t)
        disable_debug_logging()
        local cases = {
            {
                module = "oasis.chat.service.openai",
                endpoint = "https://openai.invalid/v1/chat/completions",
            },
            {
                module = "oasis.chat.service.lmstudio",
                endpoint = "https://lmstudio.invalid/api/v1/chat",
            },
        }
        for _, case in ipairs(cases) do
            local service = require(case.module)
            service.cfg = {
                endpoint = case.endpoint,
                api_key = "",
                function_calling = "0",
            }
            service.format = common.ai.format.chat
            local captured = capture_request(service, "{}")
            for _, header in ipairs(captured.headers or {}) do
                t:assert_not_contains(header, "Authorization:", case.module)
            end
        end
    end)

    harness:test("provider", "OpenAI title controls match service capabilities", function(t)
        disable_debug_logging()
        local service = require("oasis.chat.service.openai")
        local original_loader = common.load_conf_file
        common.load_conf_file = function()
            return {
                title = {
                    openai_temperature = "0.25",
                    openai_max_completion_tokens = "10",
                },
            }
        end
        t:on_cleanup(function()
            common.load_conf_file = original_loader
        end)

        local cases = {
            {
                name = "OpenAI",
                service = common.ai.service.openai.name,
                model = "gpt-4o-mini",
                temperature = 0.25,
                max_completion_tokens = 10,
            },
            {
                name = "OpenRouter reasoning model",
                service = common.ai.service.openrouter.name,
                model = "fixture/reasoning-model",
                temperature = 0.25,
            },
            {
                name = "LM Studio",
                service = common.ai.service.lmstudio.name,
                model = "local-reasoning-model",
                temperature = 0.25,
            },
            {
                name = "GPT-5",
                service = common.ai.service.openai.name,
                model = "gpt-5-mini",
            },
        }

        for _, case in ipairs(cases) do
            service.cfg = {
                service = case.service,
                model = case.model,
                function_calling = "0",
            }
            service.format = common.ai.format.title
            local encoded = service:convert_schema({
                model = case.model,
                messages = {
                    { role = "user", content = "title fixture" },
                },
            })
            local request = jsonc.parse(encoded)
            t:assert_type("table", request, case.name)
            t:assert_equal(case.temperature, request.temperature, case.name)
            t:assert_equal(case.max_completion_tokens,
                request.max_completion_tokens, case.name)
            t:assert_nil(request.max_tokens, case.name)
        end
    end)

    harness:test("provider", "OpenAI API modes and LM Studio endpoints normalize safely", function(t)
        local modes = common.ai.service.openai.api_mode
        t:assert_equal(modes.responses,
            common.resolve_openai_api_mode(modes.responses, "default"))
        t:assert_equal(modes.chat_completions,
            common.resolve_openai_api_mode(modes.chat_completions, "default"))
        t:assert_equal(modes.chat_completions,
            common.resolve_openai_api_mode("unknown", "custom"))
        t:assert_equal(modes.chat_completions,
            common.resolve_openai_api_mode(nil, "default"))

        local normalize = common.resolve_lmstudio_chat_completions_endpoint
        t:assert_equal("http://router:1234/v1/chat/completions",
            normalize(" http://router:1234/api/v1/chat/ "))
        t:assert_equal("http://router:1234/v1/chat/completions",
            normalize("http://router:1234/v1"))
        t:assert_equal("http://router:1234/v1/chat/completions",
            normalize("http://router:1234"))
        t:assert_equal("", normalize("  "))
    end)
end

return M
