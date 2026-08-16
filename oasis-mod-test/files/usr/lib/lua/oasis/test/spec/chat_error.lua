local chat_error = require("oasis.chat.error")

local M = {}

function M.register(harness)
    harness:test("unit", "provider messages are classified consistently", function(t)
        t:assert_equal("timeout",
            chat_error.classify_provider_message("request timed out"))
        t:assert_equal("connection_error",
            chat_error.classify_provider_message("connection refused"))
        t:assert_equal("unsupported_feature",
            chat_error.classify_provider_message("model does not support tools"))
        t:assert_equal("api_error",
            chat_error.classify_provider_message("rate limit exceeded"))
    end)

    harness:test("unit", "structured errors include context without config secrets", function(t)
        local service = {
            get_config = function()
                return {
                    service = "FixtureAI",
                    model = "fixture-model",
                    api_key = "OASIS_API_KEY_SENTINEL",
                }
            end,
        }
        local err = chat_error.build(service, {
            phase = "response_parse",
            kind = "parse_error",
            message = "Response was incomplete.",
            detail = "records=2",
            can_continue = false,
        })
        t:assert_equal("ERROR", err.status)
        t:assert_equal("FixtureAI", err.service)
        t:assert_equal("fixture-model", err.model)
        t:assert_false(err.can_continue)
        t:assert_contains(err.display, "Response parsing")
        t:assert_contains(err.display, "records=2")
        t:assert_not_contains(err.display, "OASIS_API_KEY_SENTINEL")
    end)

    harness:test("unit", "api_error preserves provider detail and response shape", function(t)
        local err = chat_error.api_error(nil, "connection refused")
        t:assert_equal("connection_error", err.kind)
        t:assert_equal("connection refused", err.provider_message)
        local response = chat_error.to_response(err)
        t:assert_equal(err, response.error)
        local status = chat_error.to_status(err)
        t:assert_equal("ERROR", status.status)
        t:assert_equal(err, status.error)
    end)
end

return M
