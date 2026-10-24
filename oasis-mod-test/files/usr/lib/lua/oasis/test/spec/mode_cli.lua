local M = {}
local function replace(t, name, value)
    local old = package.loaded[name]
    package.loaded[name] = value
    t:on_cleanup(function() package.loaded[name] = old end)
end
local function fixture(t)
    local env = {support={tool_auto="0", tool_auto_generation="0"}, writes=0, commits=0}
    local cursor = {}
    function cursor:get_all()
        if env.read_error then error("Read failed") end
        return env.support
    end
    function cursor:set(_, _, key, value)
        env.writes = env.writes + 1
        if env.write_error then return false end
        env.support[key] = value
        return true
    end
    replace(t, "luci.model.uci", {cursor=function() return cursor end})
    replace(t, "oasis.common", {})
    replace(t, "oasis.console", {})
    replace(t, "oasis.mode", nil)
    replace(t, "oasis.mode_lock", {with_lock=function(callback)
        if env.locked then return nil, "Lock busy" end
        return callback()
    end})
    replace(t, "oasis.uci_transaction", {run=function(_, callback)
        local before = {}
        for k,v in pairs(env.support) do before[k]=v end
        local ok, result, code = callback(cursor)
        if not ok or env.commit_error then
            env.support = before
            if env.commit_error then return false, "Commit failed", "uci_commit_failed" end
            return false, result, code
        end
        if result.changed then env.commits=env.commits+1 end
        return true, result
    end})
    local runtime = {ABI=1, available=function()
        if env.unavailable then return nil, {status="NG", code="agent_unavailable", error="Agent unavailable"} end
        return true
    end, new_policy=function() return {} end, select_tools=function() end, decorate_request=function() end}
    replace(t, "oasis.agent.runtime", runtime)
    env.runtime = runtime
    local source = debug.getinfo(1,"S").source
    local root = source:match("^@(.*)/oasis%-mod%-test/files/")
    local entry = assert(loadfile(root and root .. "/oasis/files/usr/bin/oasis" or "/usr/bin/oasis"))
    local old_arg, old_exit, old_print, old_stderr = arg, os.exit, print, io.stderr
    t:on_cleanup(function() arg, os.exit, print, io.stderr=old_arg,old_exit,old_print,old_stderr end)
    local exit = {}
    os.exit=function(code) env.code=code; error(exit,0) end
    print=function(s) env.stdout=env.stdout .. tostring(s) .. "\n" end
    io.stderr={write=function(_,s) env.stderr=env.stderr .. s end}
    function env.run(arguments)
        env.stdout,env.stderr,env.code="","",0
        arg=arguments
        local ok,err=pcall(entry)
        if not ok and err~=exit then error(err) end
        return env.code
    end
    return env
end
M.fixture = fixture

function M.register(h)
    h:test("portable","mode CLI changes shared selection without chat startup or prompts",function(t)
        local e=fixture(t)
        for _,name in ipairs({"agent","normal"}) do
            t:assert_equal(0,e.run({"mode",name}))
            t:assert_equal("Mode: "..name.."\n",e.stdout)
            t:assert_equal(name=="agent" and "1" or "0",e.support.tool_auto)
        end
        t:assert_equal(2,e.commits)
        t:assert_equal("2",e.support.tool_auto_generation)
    end)
    h:test("portable","mode CLI status and default query are read-only even when Agent is unavailable",function(t)
        local e=fixture(t);e.unavailable=true
        for _,argv in ipairs({{"mode"},{"mode","status"}}) do
            t:assert_equal(0,e.run(argv))
            t:assert_contains(e.stdout,"Mode: normal")
            t:assert_contains(e.stdout,"Agent available: no")
        end
        t:assert_equal(0,e.writes)
        t:assert_equal(0,e.commits)
    end)
    h:test("portable","mode CLI rejects invalid and surplus arguments before reading or writing",function(t)
        local e=fixture(t);e.read_error=true
        for _,argv in ipairs({{"mode","on"},{"mode","AGENT"},{"mode","agent","goal"},{"mode","status","extra"}}) do
            t:assert_equal(2,e.run(argv))
            t:assert_contains(e.stderr,"Usage:")
        end
        t:assert_equal(0,e.writes)
    end)
    h:test("portable","mode CLI cannot enable unavailable or incompatible Agent but can recover Normal",function(t)
        local e=fixture(t);e.unavailable=true
        t:assert_equal(1,e.run({"mode","agent"}))
        t:assert_equal("0",e.support.tool_auto)
        e.support.tool_auto="1"
        t:assert_equal(0,e.run({"mode","normal"}))
        t:assert_equal("0",e.support.tool_auto)
        e.runtime.ABI=99
        t:assert_equal(1,e.run({"mode","agent"}))
        t:assert_equal(0,e.run({"mode","normal"}))
    end)
    h:test("portable","mode CLI preserves the mode and generation on failed save or lock",function(t)
        for _,key in ipairs({"read_error","write_error","commit_error","locked"}) do
            local e=fixture(t);e[key]=true
            t:assert_equal(1,e.run({"mode","agent"}))
            t:assert_equal("0",e.support.tool_auto)
            t:assert_equal("0",e.support.tool_auto_generation)
        end
    end)
    h:test("portable","mode changes are idempotent and stale browser generations are rejected",function(t)
        local e=fixture(t)
        t:assert_equal(0,e.run({"mode","agent"}))
        t:assert_equal(0,e.run({"mode","agent"}))
        t:assert_equal(1,e.commits)
        local result=require("oasis.mode").set_mode("normal",nil,"0:0")
        t:assert_equal("tool_mode_changed",result.code)
        t:assert_equal("1",e.support.tool_auto)
        t:assert_equal("1",e.support.tool_auto_generation)
    end)
    h:test("portable","removed agent command reports migration without changing settings",function(t)
        local e=fixture(t)
        t:assert_equal(2,e.run({"agent","-t","8","goal"}))
        t:assert_contains(e.stderr,"oasis mode agent")
        t:assert_equal(0,e.writes)
    end)
    h:test("portable","package refresh invalidates a restored generation without changing the saved mode",function(t)
        local e=fixture(t)
        e.support.tool_auto="1";e.support.tool_auto_generation="2";e.unavailable=true
        local mode=require("oasis.mode")
        local result=mode.invalidate(nil,"9")
        t:assert_equal("OK",result.status)
        t:assert_equal("1",e.support.tool_auto)
        t:assert_equal("10",e.support.tool_auto_generation)
        t:assert_equal("invalid_tool_mode",mode.invalidate(nil,"invalid").code)
        t:assert_equal("10",e.support.tool_auto_generation)
    end)

end
return M
