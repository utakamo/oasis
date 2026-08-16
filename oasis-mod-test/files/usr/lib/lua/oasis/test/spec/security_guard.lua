local guard = require("oasis.security.guard")

local M = {}

function M.register(harness)
    harness:test("portable", "safe command identifiers are accepted", function(t)
        local accepted = {
            "network",
            "rpcd.service-1",
            "name@example:443",
            "A_B+C=1",
            "  wireless  ",
        }
        for _, value in ipairs(accepted) do
            t:assert_true(guard.check_safe_string(value), value)
        end
    end)

    harness:test("portable", "shell metacharacters and control bytes are rejected", function(t)
        local rejected = {
            "network;reboot",
            "name value",
            "a/b",
            "a|b",
            "a\nb",
            "a\0b",
            "",
            false,
        }
        for _, value in ipairs(rejected) do
            t:assert_false(guard.check_safe_string(value), tostring(value))
        end
    end)

    harness:test("portable", "encoding-spoof controls are rejected", function(t)
        local zero_width_space = "a\226\128\139b"
        local right_to_left_override = "a\226\128\174b"
        local invalid_utf8 = "a\255b"
        t:assert_false(guard.check_safe_string(zero_width_space))
        t:assert_false(guard.check_safe_string(right_to_left_override))
        t:assert_false(guard.check_safe_string(invalid_utf8))
    end)

    harness:test("portable", "sanitize removes its documented metacharacters", function(t)
        t:assert_equal("abcdefg", guard.sanitize("a;b&c|d>e<f`g"))
    end)
end

return M
