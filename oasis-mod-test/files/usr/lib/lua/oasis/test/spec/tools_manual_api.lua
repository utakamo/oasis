local state = require("oasis.local.tool.state")
local M = {}

local function fixture(t)
    local env = require("oasis.test.spec.tool_auto").fixture(t)
    env.params = {server="fixture.tools", name="weather"}
    env.function_calling = "1"
    function env.cursor:get_first() return "active" end
    function env.cursor:get() return env.function_calling end
    local modules = {
        ["oasis.local.tool.state"] = state,
        ["oasis.mode"] = require("oasis.mode"),
        ["oasis.mode_lock"] = require("oasis.mode_lock"),
        ["luci.model.uci"] = {cursor=function() return env.cursor end},
        ["luci.http"] = {prepare_content=function() end,
            write_json=function(value) env.response=value end,
            formvalue=function(key) return env.params[key] end},
        ["oasis.common"] = {db=require("oasis.common").db,
            check_server_loaded=function() return true end},
    }
    local source = debug.getinfo(1,"S").source
    local root = source:match("^@(.*)/oasis%-mod%-test/files/")
    local path = root and root .. "/oasis-mod-tool/files/luci/controller/module.lua"
        or "/usr/lib/lua/luci/controller/oasis-tool/module.lua"
    local controller = setmetatable({module=function() end,
        require=function(name) return modules[name] or {} end}, {__index=_G})
    local chunk = assert(loadfile(path))
    setfenv(chunk, controller)()
    env.controller = controller
    return env
end

function M.register(harness)
    harness:test("unit", "Tools APIs require active Function Calling only for enabling", function(t)
        for _,route in ipairs({"enable_tool", "change_tool_enable", "set_tool_auto"}) do
            local env = fixture(t)
            env.function_calling = "0"
            env.params.enable = "1"
            env.controller.local_tool_info()
            t:assert_false(env.response.can_enable)
            env.controller[route]()
            t:assert_equal("function_calling_disabled", env.response.code)
            t:assert_equal(0, env.writes)
            env.params.enable = "0"
            if route == "enable_tool" then
                env.controller.disable_tool()
            else
                env.controller[route]()
            end
            t:assert_equal("OK", env.response.status)
        end
    end)
    harness:test("unit", "legacy name-only enable checks Function Calling in the private transaction", function(t)
        local env = fixture(t)
        env.params.server, env.params.enable = nil, "1"
        local transaction = require("oasis.uci_transaction")
        local run = transaction.run
        transaction.run = function(options, callback)
            env.function_calling = "0"
            return run(options, callback)
        end
        env.controller.change_tool_enable()
        t:assert_equal("function_calling_disabled", env.response.code)
        t:assert_equal(0, env.writes)
    end)
    harness:test("unit", "Tools updates share the service lock and preserve selections when it is busy", function(t)
        local env = fixture(t)
        env.lock_busy = true
        env.controller.disable_tool()
        t:assert_equal("mode_lock_failed", env.response.code)
        t:assert_equal(0, env.writes)
    end)
    harness:test("unit", "Tools API returns editable manual settings without reading Agent state", function(t)
        for _,mode in ipairs({"0", "1", "invalid"}) do
            local env = fixture(t)
            env.support.tool_auto = mode
            env.corrupt = true
            env.controller.local_tool_info()
            t:assert_equal("OK", env.response.status)
            t:assert_equal("manual", env.response.selection_mode)
            t:assert_equal("1", env.response.tools.tool1.enable)
            t:assert_equal("0", env.response.tools.tool2.enable)
            t:assert_equal(0, env.writes)
            env.controller.disable_tool()
            t:assert_equal("OK", env.response.status)
            env.controller.local_tool_info()
            t:assert_equal("0", env.response.tools.tool1.enable)
            env.controller.enable_tool()
            t:assert_equal("OK", env.response.status)
            t:assert_equal("1", env.sections[4].enable)
            t:assert_equal(mode, env.support.tool_auto)
            t:assert_nil(env.support.tool_auto_generation)
            t:assert_nil(next(env.runtime.enabled))
        end
    end)
    harness:test("unit", "Tools legacy update route edits manual settings and still protects manager tools", function(t)
        local env = fixture(t)
        env.support.tool_auto = "1"
        env.params.enable = "0"
        env.params.server = nil
        env.controller.change_tool_enable()
        t:assert_equal("OK", env.response.status)
        t:assert_equal("0", env.sections[4].enable)
        env.params.server = "oasis.tool.manager"
        env.params.name = "get_tool_list"
        for _,route in ipairs({"enable_tool", "disable_tool", "change_tool_enable"}) do
            env.controller[route]()
            t:assert_equal("protected_control_tool", env.response.code)
        end
    end)
    harness:test("unit", "Tools API preserves manual settings on failed save and rejects conflicts", function(t)
        local env = fixture(t)
        env.support.tool_auto = "1"
        env.commit_fails = true
        env.controller.disable_tool()
        t:assert_equal("NG", env.response.status)
        env.controller.local_tool_info()
        t:assert_equal("1", env.response.tools.tool1.enable)
        env.commit_fails = false
        env.sections[4].conflict = "1"
        env.controller.disable_tool()
        t:assert_equal("tool_conflict", env.response.code)
        t:assert_equal("1", env.sections[4].enable)
    end)
end
return M
