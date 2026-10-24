local M = {}
local function replace(t, name, value)
    local old = package.loaded[name]
    package.loaded[name] = value
    t:on_cleanup(function() package.loaded[name] = old end)
end
local function fixture(t)
    local env = {support={tool_auto="0", tool_auto_generation="0"}, writes=0, commits=0,
        function_calling="1"}
    local cursor = {}
    env.cursor = cursor
    function cursor:get_first() return "active" end
    function cursor:get() return env.function_calling end
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

local function settings_fixture(t)
    local e=fixture(t)
    e.services={
        {[".name"]="first",identifier="one",name="OpenAI",model="model",function_calling="1"},
        {[".name"]="second",identifier="two",name="LM Studio",model="model",function_calling="0"},
    }
    e.support.tool_auto="1"
    local function copy(value)
        if type(value)~="table" then return value end
        local result={}
        for k,v in pairs(value) do result[k]=copy(v) end
        return result
    end
    local saved={support=copy(e.support),services=copy(e.services)}
    local uci=e.cursor
    function uci:get_first(_,_,option) return e.services[1] and e.services[1][option or ".name"] end
    function uci:get(_,section,option)
        for _,service in ipairs(e.services) do
            if service[".name"]==section then return service[option] end
        end
    end
    local set=uci.set
    function uci:set(config,section,option,value)
        if section=="support" then return set(self,config,section,option,value) end
        for _,service in ipairs(e.services) do
            if service[".name"]==section then service[option]=value; return true end
        end
        return false
    end
    function uci:delete(_,section,option)
        for i,service in ipairs(e.services) do
            if service[".name"]==section then
                if option then service[option]=nil else table.remove(e.services,i) end
                return true
            end
        end
        return false
    end
    function uci:foreach(_,kind,callback)
        if kind==nil then callback({[".name"]="support",[".type"]="support"}) end
        for _,service in ipairs(e.services) do
            local entry=copy(service); entry[".type"]="service"
            if callback(entry)==false then break end
        end
        return true
    end
    function uci:reorder(_,order)
        if e.reorder_error then return false end
        if type(order)=="string" then order={order} end
        local reordered,seen={},{}
        for _,name in ipairs(order) do
            for _,service in ipairs(e.services) do
                if service[".name"]==name then reordered[#reordered+1]=service; seen[name]=true end
            end
        end
        for _,service in ipairs(e.services) do
            if not seen[service[".name"]] then reordered[#reordered+1]=service end
        end
        e.services=reordered
        return true
    end
    function uci:commit()
        if e.commit_error then return false end
        e.commits=e.commits+1
        saved={support=copy(e.support),services=copy(e.services)}
        return true
    end
    function uci:revert()
        e.support,e.services=copy(saved.support),copy(saved.services)
        return true
    end
    local transaction={run=function(_,callback)
        local ok,result,code=callback(uci)
        if not ok or not uci:commit() then
            uci:revert()
            return false,not ok and result or "Commit failed",code or "uci_commit_failed"
        end
        return true,result
    end}
    local mode=require("oasis.mode")
    local modules={
        ["luci.model.uci"]={cursor=function() return uci end},
        ["luci.http"]={prepare_content=function() end,write_json=function(value) e.response=value end,
            formvalue=function(key) return e.params[key] end},
        ["oasis.mode"]=mode,["oasis.mode_lock"]=require("oasis.mode_lock"),
        ["oasis.uci_transaction"]=transaction,
    }
    local source=debug.getinfo(1,"S").source
    local root=source:match("^@(.*)/oasis%-mod%-test/files/")
    local path=root and root.."/oasis/files/luci/controller/module.lua"
        or "/usr/lib/lua/luci/controller/oasis/module.lua"
    local controller=setmetatable({module=function() end,
        require=function(name) return modules[name] or {} end},{__index=_G})
    if setfenv then
        setfenv(assert(loadfile(path)),controller)()
    else
        assert(loadfile(path,"t",controller))()
    end
    local function upvalue(fn,wanted)
        for i=1,100 do
            local name,value=debug.getupvalue(fn,i)
            if name==wanted then return value end
            if not name then break end
        end
        error("Missing upvalue: "..wanted)
    end
    local apply=upvalue(upvalue(controller.update_settings,"settings_update_locked"),"settings_apply_update")
    function e.save(services)
        local names={}
        for _,service in ipairs(e.services) do names[#names+1]=service[".name"] end
        local payload=copy(services or e.services)
        for _,service in ipairs(payload) do service._section=service[".name"]; service[".name"]=nil end
        return apply({settings={},services=payload},{service_sections=names})
    end
    e.controller=controller
    e.params={identifier="two",name="LM Studio",model="model"}
    return e
end

function M.register(h)
    h:test("portable","settings save commits Function Calling OFF and Agent OFF together",function(t)
        local e=settings_fixture(t)
        e.services[1].function_calling="0"
        t:assert_true(e.save())
        t:assert_equal("0",e.support.tool_auto)
        t:assert_equal("1",e.support.tool_auto_generation)
        t:assert_equal(1,e.commits)
        t:assert_true(e.save())
        t:assert_equal("1",e.support.tool_auto_generation)
    end)
    h:test("portable","settings save preserves Agent for an inactive service and disables it after service removal",function(t)
        local e=settings_fixture(t)
        t:assert_true(e.save())
        t:assert_equal("1",e.support.tool_auto)
        t:assert_equal("0",e.support.tool_auto_generation)
        t:assert_true(e.save({}))
        t:assert_equal("0",e.support.tool_auto)
        t:assert_equal("1",e.support.tool_auto_generation)
    end)
    h:test("portable","failed settings save restores Function Calling and Agent mode",function(t)
        for _,fault in ipairs({"commit_error","write_error"}) do
            local e=settings_fixture(t)
            local payload={{[".name"]="first",identifier="one",name="OpenAI",model="model",function_calling="0"}}
            e[fault]=true
            t:assert_false(e.save(payload))
            t:assert_equal("1",e.support.tool_auto)
            t:assert_equal("0",e.support.tool_auto_generation)
            t:assert_equal("1",e.services[1].function_calling)
            t:assert_equal(0,e.commits)
        end
    end)
    h:test("portable","service selection automatically disables Agent and never restores it on switching back",function(t)
        local e=settings_fixture(t)
        e.controller.select_ai_service()
        t:assert_equal("OK",e.response.status)
        t:assert_equal("second",e.services[1][".name"])
        t:assert_equal("0",e.support.tool_auto)
        t:assert_equal("1",e.support.tool_auto_generation)
        e.params={identifier="one",name="OpenAI",model="model"}
        e.controller.select_ai_service()
        t:assert_equal("OK",e.response.status)
        t:assert_equal("0",e.support.tool_auto)
        t:assert_equal("1",e.support.tool_auto_generation)
        e.params.mode="agent"
        e.controller.set_mode()
        t:assert_equal("OK",e.response.status)
    end)
    h:test("portable","failed service selection preserves service order and Agent generation",function(t)
        for _,fault in ipairs({"commit_error","write_error","reorder_error","locked"}) do
            local e=settings_fixture(t);e[fault]=true
            e.controller.select_ai_service()
            t:assert_equal("NG",e.response.status)
            t:assert_equal("first",e.services[1][".name"])
            t:assert_equal("1",e.support.tool_auto)
            t:assert_equal("0",e.support.tool_auto_generation)
        end
    end)
    h:test("portable","mode HTTP API gates enabling and accepts LM Studio with Function Calling",function(t)
        local e=settings_fixture(t)
        e.services[1].function_calling="0"
        e.controller.get_mode()
        t:assert_false(e.response.can_enable)
        e.params.mode="agent"
        e.controller.set_mode()
        t:assert_equal("function_calling_disabled",e.response.code)
        e.services[1].function_calling=nil
        e.services[2].function_calling="1"
        e.controller.get_mode()
        t:assert_false(e.response.can_enable,"a later service must not override the active service's missing flag")
        e.services[1].function_calling,e.services[1].name="1","LM Studio"
        e.controller.get_mode()
        t:assert_true(e.response.can_enable)
        t:assert_nil(e.response.service_reason_code)
    end)
    h:test("portable","UI mode checks Function Calling without changing CLI mode semantics",function(t)
        local e=fixture(t)
        local mode=require("oasis.mode")
        local options={require_function_calling=true}
        for _,flag in ipairs({"0", "", "invalid", false}) do
            e.function_calling=flag
            t:assert_false(mode.get_status(e.cursor,options).can_enable)
            local result=mode.set_mode("agent",e.cursor,nil,nil,options)
            t:assert_equal("function_calling_disabled",result.code)
            t:assert_equal(0,e.writes)
        end
        e.function_calling="1"
        t:assert_true(mode.get_status(e.cursor,options).can_enable)
        t:assert_equal("OK",mode.set_mode("agent",e.cursor,nil,nil,options).status)
        e.function_calling="0"
        t:assert_equal("OK",mode.set_mode("normal",e.cursor,nil,nil,options).status)
        t:assert_equal(0,e.run({"mode","agent"}))
    end)
    h:test("portable","automatic Agent OFF increments the generation once and never re-enables",function(t)
        local e=fixture(t)
        local mode=require("oasis.mode")
        t:assert_equal(0,e.run({"mode","agent"}))
        t:assert_false(mode.reconcile_function_calling(e.cursor).changed)
        e.function_calling="0"
        t:assert_true(mode.reconcile_function_calling(e.cursor).changed)
        t:assert_equal("0",e.support.tool_auto)
        t:assert_equal("2",e.support.tool_auto_generation)
        t:assert_false(mode.reconcile_function_calling(e.cursor).changed)
        t:assert_equal("2",e.support.tool_auto_generation)
        e.function_calling="1"
        t:assert_false(mode.reconcile_function_calling(e.cursor).changed)
        t:assert_equal("0",e.support.tool_auto)
        t:assert_equal(1,e.commits,"reconciliation only stages changes for its caller")
    end)
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
