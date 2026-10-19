local jsonc = require("luci.jsonc")
local common = require("oasis.common")
local schema = require("oasis.unified.chat.schema")

local M = {}
local SENTINEL = "OASIS_PRIVATE_SENTINEL"

local function parse_object(t, text, label)
    local ok, value = pcall(jsonc.parse, text)
    t:assert_true(ok, label .. ": parse failed")
    t:assert_type("table", value, label .. ": expected object")
    return value
end

local function sanitize(t, input, label)
    local encoded, err = schema.sanitize_tool_output_for_ai(input)
    t:assert_type("string", encoded, label .. ": " .. tostring(err))
    return parse_object(t, encoded, label), encoded
end

function M.register(harness)
    local ok, logger = pcall(require, "oasis.chat.debug")
    if ok and type(logger) == "table" then
        logger.disabled = true
    end

    harness:test("unit", "tool output removes every top-level user_only value", function(t)
        local inputs = {
            '{"result":"ok","user_only":"' .. SENTINEL .. '"}',
            '{"result":"ok","user_only":""}',
            '{"result":"ok","user_only":false}',
            '{"result":"ok","user_only":{"ssid":"private"}}',
        }
        for index, input in ipairs(inputs) do
            local result, encoded = sanitize(t, input, "case " .. index)
            t:assert_equal("ok", result.result)
            t:assert_nil(result.user_only)
            t:assert_not_contains(encoded, SENTINEL)
        end
    end)

    harness:test("unit", "nested user_only is not treated as the reserved channel", function(t)
        local result = sanitize(t,
            '{"result":"ok","nested":{"user_only":"nested"}}',
            "nested user_only")
        t:assert_type("table", result.nested)
        t:assert_equal("nested", result.nested.user_only)
    end)

    harness:test("unit", "ui_action is removed from direct and rpcd wrapped output without mutating UI data", function(t)
        local payload = { status = "input_required", request = "Wait for user input.",
            ui_action = { version = 1, type = "fixture", fields = { { label = SENTINEL } } },
            user_only = SENTINEL }
        local raw = jsonc.stringify(payload, false)
        local source = { result = raw, ui_action = payload.ui_action, user_only = SENTINEL }
        local cleaned, encoded = sanitize(t, source, "wrapped form")
        t:assert_equal(raw, source.result)
        t:assert_type("table", source.ui_action)
        t:assert_nil(cleaned.ui_action)
        t:assert_nil(cleaned.user_only)
        t:assert_not_contains(encoded, SENTINEL)
        t:assert_not_contains(encoded, "ui_action")
        t:assert_not_contains(encoded, "user_only")
        local inner = parse_object(t, cleaned.result, "inner result")
        t:assert_equal("input_required", inner.status)
        for _, value in ipairs({ raw, payload, { result = payload },
            { result = jsonc.stringify({ result = raw }, false) } }) do
            local _, text = sanitize(t, value, "form representation")
            t:assert_not_contains(text, SENTINEL)
            t:assert_not_contains(text, "ui_action")
        end
    end)

    harness:test("unit", "ui_action is reserved regardless of its JSON value", function(t)
        for _, raw in ipairs({ '{"ui_action":null}', '{"ui_action":false}',
            '{"ui_action":"private"}', '{"ui_action":[]}' }) do
            local result = sanitize(t, raw, "reserved ui_action")
            t:assert_nil(result.ui_action)
        end
    end)

    harness:test("unit", "table input is sanitized without mutation", function(t)
        local source = {
            result = "ok",
            request = "shown",
            user_only = SENTINEL,
        }
        local result, encoded = sanitize(t, source, "table input")
        t:assert_equal(SENTINEL, source.user_only)
        t:assert_equal("ok", result.result)
        t:assert_equal("shown", result.request)
        t:assert_nil(result.user_only)
        t:assert_not_contains(encoded, SENTINEL)
    end)

    harness:test("unit", "malformed and non-object tool outputs fail closed", function(t)
        local inputs = {
            '{"result":"ok","user_only":"unterminated"',
            '["not","an","object"]',
            "null",
            nil,
            true,
        }
        for index = 1, 5 do
            local encoded, err = schema.sanitize_tool_output_for_ai(inputs[index])
            t:assert_nil(encoded, "case " .. index)
            t:assert_type("string", err, "case " .. index)
        end
    end)

    harness:test("unit", "normalize_arguments accepts objects only", function(t)
        t:assert_deep_equal({}, schema.normalize_arguments("{}"))
        t:assert_deep_equal({ name = "value" },
            schema.normalize_arguments('{"name":"value"}'))
        t:assert_deep_equal({}, schema.normalize_arguments('["value"]'))
        t:assert_deep_equal({}, schema.normalize_arguments("not-json"))
        t:assert_deep_equal({ count = 2 },
            schema.normalize_arguments({ count = 2 }))
        t:assert_deep_equal({}, schema.normalize_arguments({ "value" }))
    end)

    harness:test("unit", "setup_msg preserves the raw UI event but stores sanitized content", function(t)
        local service = {
            handle_tool_result = function(_, chat, speaker, msg)
                if speaker.role ~= "tool" then
                    return nil
                end
                msg.name = speaker.name
                msg.tool_call_id = speaker.tool_call_id
                msg.content = speaker.content
                chat.messages[#chat.messages + 1] = msg
                return true
            end,
            handle_tool_call = function()
                return nil
            end,
            get_config = function()
                return {}
            end,
            get_format = function()
                return common.ai.format.chat
            end,
        }
        local raw_content = jsonc.stringify({
            result = "ok",
            user_only = SENTINEL,
        }, false)
        local speaker = {
            role = "tool",
            name = "wifi_scan",
            tool_call_id = "call-1",
            content = raw_content,
        }
        local chat = { messages = {} }

        t:assert_true(schema.setup_msg(service, chat, speaker))
        t:assert_equal(raw_content, speaker.content,
            "UI-facing event was mutated")
        t:assert_equal(1, #chat.messages)
        t:assert_not_contains(chat.messages[1].content, SENTINEL)
        local stored = parse_object(t, chat.messages[1].content, "stored tool output")
        t:assert_equal("ok", stored.result)
        t:assert_nil(stored.user_only)
    end)
end

return M
