local M = {}

local function replace(t, name, value)
    local previous = package.loaded[name]
    package.loaded[name] = value
    t:on_cleanup(function() package.loaded[name] = previous end)
end

-- Exercise the real sequence, state reader, capability checks and prompt helper.
-- Only platform I/O and transport are mocked; no live settings or tools change.
local function fixture(t)
    local env = { support = { local_tool = "1", tool_auto = "1", tool_auto_generation = "0" },
        mode_reads = 0, prompt_reads = 0, requests = 0, effects = 0, outgoing = {} }
    local cursor = {
        get_bool = function(_, _, _, option) return env.support[option] == "1" end,
        get_all = function()
            env.mode_reads = env.mode_reads + 1
            if env.read_error then error("fixture: mode read unavailable") end
            return env.support
        end,
        get = function(_, _, _, option)
            if option == "tool_auto" then
                env.prompt_reads = env.prompt_reads + 1
                if env.read_error then error("fixture: Auto prompt setting unavailable") end
            end
            return env.support[option]
        end,
    }
    replace(t, "luci.model.uci", { cursor = function() return cursor end })
    for _, name in ipairs({ "ubus", "luci.sys", "luci.util", "oasis.chat.misc" }) do
        replace(t, name, {})
    end
    replace(t, "oasis.chat.debug", { log = function() end })
    -- A round-trip fixture codec is sufficient here: JSON parsing correctness is
    -- covered by the provider suites. Tool identity uses the real policy code.
    local encoded = {}
    local jsonc = {
        stringify = function(value)
            if type(value) == "string" then return string.format("%q", value) end
            if type(value) ~= "table" then return tostring(value) end
            local token = "fixture-json-" .. tostring(#encoded + 1)
            encoded[#encoded + 1] = token
            encoded[token] = value
            return token
        end,
        parse = function(value) return encoded[value] end,
    }
    replace(t, "luci.jsonc", jsonc)
    for _, name in ipairs({ "oasis.common", "oasis.chat.error",
        "oasis.chat.function.calling.policy", "oasis.unified.chat.schema",
        "oasis.chat.tool_sequence", "oasis.local.tool.state" }) do
        replace(t, name, nil)
    end
    local schema = require("oasis.unified.chat.schema")
    env.schema = schema
    env.service = {
        cfg = { function_calling = "1" }, format = "chat",
        get_config = function(self) return self.cfg end,
        get_format = function(self) return self.format end,
        get_tool_side_effects_committed = function() return env.effects > 0 end,
        handle_tool_output = function()
            if env.after_tool then env.after_tool() end
            return true
        end,
    }
    env.chat = { messages = { { role = "system", content = "Selected prompt" },
        { role = "user", content = "Fixture request" } } }
    env.call = { name = "fixture_tool", arguments = {}, tool_call_id = "fixture-1",
        output = { status = "OK" } }
    replace(t, "oasis.chat.transfer", { chat_with_ai = function(service, chat)
        env.requests = env.requests + 1
        env.outgoing[env.requests] = schema.with_auto_tool_search_prompt(service, chat)
        if env.on_request then return env.on_request(service, chat) end
        return nil, "Fixture answer", false
    end })
    env.sequence = require("oasis.chat.tool_sequence")
    function env.run(options) return env.sequence.run(env.service, env.chat, options) end
    function env.authorize_and_execute()
        local allowed, err = env.service._tool_sequence_context.authorize_tool_batch({ env.call })
        if not allowed then return nil, nil, false, err end
        env.effects = env.effects + 1
        return jsonc.stringify({ tool_outputs = { env.call } }), nil, true
    end
    return env
end

function M.register(harness)
    harness:test("portable", "tool mode is not read when local tools or Function Calling are disabled", function(t)
        for _, flags in ipairs({ { "0", "1" }, { "1", "0" }, { "0", "0" } }) do
            for _, broken in ipairs({ "invalid", "unreadable" }) do
                local env = fixture(t)
                env.support.local_tool, env.service.cfg.function_calling = flags[1], flags[2]
                env.support.tool_auto_generation = "invalid"
                env.read_error = broken == "unreadable"
                local result = env.run()
                t:assert_true(result.ok)
                t:assert_equal("Fixture answer", result.message)
                t:assert_equal(1, env.requests)
                t:assert_equal(0, env.mode_reads)
                t:assert_equal(0, env.prompt_reads)
                t:assert_equal(env.chat, env.outgoing[1])
            end
        end
    end)

    harness:test("portable", "tool mode and Auto prompt are not read for title requests", function(t)
        local env = fixture(t)
        env.service.format, env.read_error = "ai_create_title", true
        t:assert_true(env.run().ok)
        t:assert_equal(0, env.mode_reads)
        t:assert_equal(0, env.prompt_reads)
        t:assert_equal(env.chat, env.outgoing[1])
    end)

    harness:test("portable", "tool mode dependency is not loaded for core-only text requests", function(t)
        local env = fixture(t)
        env.support.local_tool = "0"
        local name = "oasis.local.tool.state"
        local previous = package.preload[name]
        local loads = 0
        replace(t, name, nil)
        package.preload[name] = function() loads = loads + 1; error("fixture: package absent") end
        t:on_cleanup(function() package.preload[name] = previous end)
        t:assert_true(env.run().ok)
        t:assert_equal(0, loads)
        t:assert_equal(0, env.mode_reads)
    end)

    harness:test("portable", "tool mode remains fail-closed for tool-capable requests", function(t)
        for _, broken in ipairs({ "invalid", "unreadable" }) do
            local env = fixture(t)
            env.support.tool_auto_generation = "invalid"
            env.read_error = broken == "unreadable"
            local result = env.run()
            t:assert_false(result.ok)
            t:assert_contains(result.error.message, "Failed to read the tool mode")
            t:assert_equal(0, env.requests)
            t:assert_equal(1, env.mode_reads)
        end
    end)

    harness:test("portable", "tool mode changes cannot bypass dispatch checks by disabling capabilities mid-request", function(t)
        for _, option in ipairs({ "none", "local_tool", "function_calling" }) do
            local env = fixture(t)
            env.service._tool_mode_token = "outer-token"
            env.on_request = function()
                env.support.tool_auto_generation = "1"
                if option == "local_tool" then env.support.local_tool = "0" end
                if option == "function_calling" then env.service.cfg.function_calling = "0" end
                return env.authorize_and_execute()
            end
            local result = env.run()
            t:assert_false(result.ok)
            t:assert_contains(result.error.message, "Tool mode changed")
            t:assert_equal(0, env.effects)
            t:assert_equal(2, env.mode_reads)
            t:assert_equal("outer-token", env.service._tool_mode_token)
        end
    end)

    harness:test("portable", "tool mode is not read for unexpected calls from a text-only request", function(t)
        for _, option in ipairs({ "local_tool", "function_calling" }) do
            local env = fixture(t)
            if option == "local_tool" then env.support.local_tool = "0" end
            if option == "function_calling" then env.service.cfg.function_calling = "0" end
            env.on_request = function()
                env.support.local_tool, env.service.cfg.function_calling = "1", "1"
                return env.authorize_and_execute()
            end
            local result = env.run()
            t:assert_false(result.ok)
            t:assert_contains(result.error.message, "local tools were disabled")
            t:assert_equal(0, env.mode_reads)
            t:assert_equal(0, env.prompt_reads)
            t:assert_equal(0, env.effects)
        end
    end)

    harness:test("portable", "tool mode failure does not block the final no-tool answer after an executed tool", function(t)
        local env = fixture(t)
        env.on_request = function()
            if env.requests == 1 then return env.authorize_and_execute() end
            return nil, "Final answer", false
        end
        env.after_tool = function() env.read_error = true end
        local result = env.run()
        t:assert_true(result.ok)
        t:assert_equal("Final answer", result.message)
        t:assert_equal(2, env.requests)
        t:assert_equal(1, env.effects)
        t:assert_equal(2, env.mode_reads)
        t:assert_equal(1, env.prompt_reads)
        t:assert_equal(env.chat, env.outgoing[2])
    end)

    harness:test("portable", "tool mode checks remain active for tool-capable agent continuations", function(t)
        local env = fixture(t)
        env.on_request = function() return env.authorize_and_execute() end
        env.after_tool = function() env.support.tool_auto_generation = "1" end
        local result = env.run({ allow_normal_tool_chaining = true })
        t:assert_false(result.ok)
        t:assert_contains(result.error.message, "Tool mode changed")
        t:assert_false(result.error.can_continue)
        t:assert_equal(1, env.requests)
        t:assert_equal(1, env.effects)
    end)

    harness:test("portable", "tool mode is not read when a sequence limit requires a no-tool request", function(t)
        local env = fixture(t)
        env.read_error = true
        local result = env.run({ max_ai_requests = 1 })
        t:assert_true(result.limit_reached)
        t:assert_equal(1, env.requests)
        t:assert_equal(0, env.mode_reads)
        t:assert_equal(0, env.prompt_reads)
        t:assert_equal(env.chat, env.outgoing[1])
    end)

    harness:test("portable", "tool mode prompt skips Auto settings for legacy no-tool continuations", function(t)
        local env = fixture(t)
        env.read_error = true
        env.chat.messages[#env.chat.messages + 1] = { role = "tool", content = "Fixture result" }
        t:assert_equal(env.chat, env.schema.with_auto_tool_search_prompt(env.service, env.chat))
        t:assert_equal(0, env.prompt_reads)
    end)
end

return M
