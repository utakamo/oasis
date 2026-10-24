local state = require("oasis.local.tool.state")
local M = {}

local function fixture(t)
    local env = require("oasis.test.spec.tool_auto").fixture(t)
    env.params = {server="fixture.tools", name="weather"}
    local modules = {
        ["oasis.local.tool.state"] = state,
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
