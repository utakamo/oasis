local M = {}

local function fixture(t, reads)
    local env = { chats = {}, services = {}, closed = 0 }
    local cursor = {
        foreach = function(_, _, _, callback)
            for _, id in ipairs(env.chats) do callback({ id = id }) end
        end,
        get_all = function() return env.services end,
    }
    local modules = {
        ["ubus"] = {},
        ["luci.model.uci"] = { cursor = function() return cursor end },
        ["luci.sys"] = { exec = function()
            error("ID generation must not execute shell commands")
        end },
        ["oasis.chat.misc"] = {},
    }
    for name, value in pairs(modules) do
        local previous = package.loaded[name]
        package.loaded[name] = value
        t:on_cleanup(function() package.loaded[name] = previous end)
    end
    local previous = package.loaded["oasis.common"]
    package.loaded["oasis.common"] = nil
    t:on_cleanup(function() package.loaded["oasis.common"] = previous end)

    if reads then
        local original_open = io.open
        local index = 0
        io.open = function(path, mode)
            t:assert_equal("/dev/urandom", path)
            t:assert_equal("rb", mode)
            if env.open_error then return nil, "Cannot open random source" end
            return {
                read = function()
                    index = index + 1
                    return reads[index]
                end,
                close = function() env.closed = env.closed + 1 end,
            }
        end
        t:on_cleanup(function() io.open = original_open end)
    end
    env.common = require("oasis.common")
    return env
end

function M.register(harness)
    harness:test("portable", "random IDs retain ten digits and leading zeroes across reads", function(t)
        local env = fixture(t, { "\0\255abc", "01x2\n3", "456789987654" })
        t:assert_equal("0123456789", env.common.generate_chat_id())
        t:assert_equal(1, env.closed)
    end)

    harness:test("portable", "random IDs retry chat and service collisions", function(t)
        local env = fixture(t, {
            "0123456789", "1234567890", "2345678901", "3456789012",
        })
        env.chats = { "0123456789" }
        env.services = { service = { [".type"] = "service", identifier = "2345678901" } }
        t:assert_equal("1234567890", env.common.generate_chat_id())
        t:assert_equal("3456789012", env.common.generate_service_id("urandom"))
        t:assert_equal(4, env.closed)
    end)

    harness:test("portable", "random IDs stop after exhausting collision retries", function(t)
        local env = fixture(t, {
            "0123456789", "0123456789", "0123456789", "0123456789", "0123456789",
        })
        env.chats = { "0123456789" }
        t:assert_equal("", env.common.generate_chat_id())
        t:assert_equal(5, env.closed)
    end)

    harness:test("portable", "random IDs fail without returning partial digits on read errors", function(t)
        local env = fixture(t, { "0123" })
        t:assert_equal("", env.common.generate_chat_id())
        t:assert_equal(1, env.closed)
        t:assert_equal("", env.common.generate_service_id("urandom"))
        t:assert_equal(2, env.closed)
        env.open_error = true
        t:assert_equal("", env.common.generate_chat_id())
        t:assert_equal(2, env.closed)
    end)

    harness:test("portable", "random IDs work with the real random source without shell commands", function(t)
        local env = fixture(t)
        for _ = 1, 50 do
            for _, id in ipairs({
                env.common.generate_chat_id(), env.common.generate_service_id("urandom"),
            }) do
                t:assert_equal(10, #id)
                t:assert_nil(id:find("[^0-9]"))
            end
        end
    end)
end

return M
