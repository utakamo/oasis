local jsonc = require("luci.jsonc")

local M = {}

local function disable_debug_logging()
    local ok, logger = pcall(require, "oasis.chat.debug")
    if ok and type(logger) == "table" then
        logger.disabled = true
    end
end

local function feed_bytewise(service, payload)
    local frames = {}
    for index = 1, #payload do
        local produced, err = service:frame_ai_response(
            payload:sub(index, index),
            false
        )
        if err then
            return frames, err
        end
        for _, frame in ipairs(produced or {}) do
            frames[#frames + 1] = frame
        end
    end
    local produced, err = service:frame_ai_response("", true)
    for _, frame in ipairs(produced or {}) do
        frames[#frames + 1] = frame
    end
    return frames, err
end

function M.register(harness)
    harness:test("provider", "SSE providers preserve events under bytewise input", function(t)
        disable_debug_logging()
        local providers = {
            {
                name = "Anthropic",
                module = "oasis.chat.service.anthropic",
            },
            {
                name = "Gemini",
                module = "oasis.chat.service.gemini",
            },
            {
                name = "OpenAI Responses",
                module = "oasis.chat.service.openai_responses",
            },
            {
                name = "LM Studio",
                module = "oasis.chat.service.lmstudio",
            },
        }
        local payload = table.concat({
            "event: first\r\n",
            "data: {\"value\":1}\r\n",
            "\r\n",
            "event: second\r\n",
            "data: {\"value\":2}\r\n",
            "\r\n",
        })
        local expected = {
            "event: first\ndata: {\"value\":1}",
            "event: second\ndata: {\"value\":2}",
        }

        for _, provider in ipairs(providers) do
            local service = require(provider.module)
            service:reset_ai_response_framer()
            local frames, err = feed_bytewise(service, payload)
            t:assert_nil(err, provider.name)
            t:assert_deep_equal(expected, frames, provider.name)
        end
    end)

    harness:test("provider", "SSE providers buffer a JSON response until EOF", function(t)
        disable_debug_logging()
        local modules = {
            "oasis.chat.service.anthropic",
            "oasis.chat.service.gemini",
            "oasis.chat.service.openai_responses",
            "oasis.chat.service.lmstudio",
        }
        for _, module_name in ipairs(modules) do
            local service = require(module_name)
            service:reset_ai_response_framer()
            local frames, err = service:frame_ai_response(
                " {\"message\":",
                false
            )
            t:assert_nil(err, module_name)
            t:assert_deep_equal({}, frames, module_name)
            frames, err = service:frame_ai_response("\"ok\"}", true)
            t:assert_nil(err, module_name)
            t:assert_deep_equal(
                { ' {"message":"ok"}' },
                frames,
                module_name
            )
        end
    end)

    harness:test("provider", "Ollama NDJSON framing preserves complete records", function(t)
        disable_debug_logging()
        local service = require("oasis.chat.service.ollama")
        service:reset_ai_response_framer()
        local payload = table.concat({
            '{"message":{"role":"assistant","content":"A"},"done":false}\r\n',
            '{"message":{"role":"assistant","content":"B"},"done":true}\r\n',
        })
        local expected = {
            '{"message":{"role":"assistant","content":"A"},"done":false}',
            '{"message":{"role":"assistant","content":"B"},"done":true}',
        }
        local frames, err = feed_bytewise(service, payload)
        t:assert_nil(err)
        t:assert_deep_equal(expected, frames)
    end)

    harness:test("provider", "OpenAI Chat Completions accepts fragmented JSON", function(t)
        disable_debug_logging()
        local service = require("oasis.chat.service.openai")
        service.chunk_all = ""
        service.mark = {}
        service.recv_raw_msg = { role = "unknown", message = "" }
        service.cfg = {
            service = "OpenAI",
            model = "fixture-model",
            function_calling = "0",
            show_thinking = "0",
        }

        local text, response, _, used, err = service:recv_ai_msg(
            '{"choices":[{"message":{"role":"assistant","content":"Hel'
        )
        t:assert_equal("", text)
        t:assert_equal("", response)
        t:assert_false(used)
        t:assert_nil(err)

        text, response, _, used, err = service:recv_ai_msg('lo"}}]}')
        t:assert_equal("Hello", text)
        t:assert_false(used)
        t:assert_nil(err)
        local decoded = jsonc.parse(response)
        t:assert_equal("Hello", decoded.message.content)
        t:assert_equal("Hello", service.recv_raw_msg.message)
    end)

    harness:test("provider", "Ollama completion state rejects trailing records", function(t)
        disable_debug_logging()
        local service = require("oasis.chat.service.ollama")
        service.cfg = {
            service = "Ollama",
            model = "fixture-model",
            function_calling = "0",
            show_thinking = "0",
        }
        service.format = "output"
        service:init_msg_buffer()

        local text, _, _, used, err = service:recv_ai_msg(
            '{"message":{"role":"assistant","content":"Hel"},"done":false}'
        )
        t:assert_equal("Hel", text)
        t:assert_false(used)
        t:assert_nil(err)

        text, _, _, used, err = service:recv_ai_msg(
            '{"message":{"role":"assistant","content":"lo"},"done":true}'
        )
        t:assert_equal("lo", text)
        t:assert_false(used)
        t:assert_nil(err)
        t:assert_nil(service:validate_ai_response_complete())
        t:assert_equal("Hello", service.recv_raw_msg.message)

        _, _, _, _, err = service:recv_ai_msg(
            '{"message":{"role":"assistant","content":"extra"},"done":true}'
        )
        t:assert_type("table", err)
        t:assert_equal("parse_error", err.kind)
        t:assert_contains(err.message, "after the completion")
    end)
end

return M
