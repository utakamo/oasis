local M = {}
local function fixture(t)
    local env = {mode="1",generation=3,marker=true,selected=true,applies=0,invalidations=0,
        sections={
            owned={[".name"]="owned",manifest_path="/etc/oasis/tool-manifest.d/lua.oasis.tool.manager.json"},
            legacy={[".name"]="legacy",server="oasis.tool.manager",name="set_tool_enabled"},
            custom={[".name"]="custom",manifest_path="/etc/oasis/tool-manifest.d/custom.json",server="oasis.tool.manager",name="set_tool_enabled"},
            manual={[".name"]="manual",server="fixture",name="inspect",enable="1"},
        }}
    local cursor={foreach=function(_,_,_,fn) for _,s in pairs(env.sections) do fn(s) end return true end,
        delete=function(_,_,key) env.sections[key]=nil;return true end}
    local modules={
        ["luci.model.uci"]={cursor=function() return cursor end},
        ["oasis.mode"]={
            set_mode=function(name)
                if env.fail_mode then return {status="NG",error="mode failed"} end
                assert(name=="normal");env.mode="0";return {status="OK"}
            end,
            invalidate=function(_,floor)
                env.invalidations=env.invalidations+1
                if env.fail_invalidate then return {status="NG",error="generation failed"} end
                env.generation=math.max(env.generation,tonumber(floor) or 0)+1
                return {status="OK"}
            end,
        },
        ["nixio.fs"]={stat=function() return env.marker end,
            unlink=function() env.marker=false;return true end,
            writefile=function() env.marker=true;return true end},
        ["oasis.uci_transaction"]={run=function(_,callback) return callback(cursor) end},
        ["oasis.mode_lock"]={with_lock=function(callback) return callback() end},
        ["oasis.agent.store"]={write=function(value) assert(next(value.enabled)==nil);env.selected=false;return true end},
        ["oasis.local.tool.client"]={apply_manifest_file=function(path,options)
            assert(path=="/etc/oasis/tool-manifest.d/lua.oasis.tool.manager.json")
            assert(options.preserve_local_tool_support)
            env.applies=env.applies+1
            if env.fail_apply then return nil,"apply failed" end
            return true
        end},
    }
    function env.run(args)
        local source=debug.getinfo(1,"S").source
        local root=source:match("^@(.*)/oasis%-mod%-test/files/")
        local entry=assert(loadfile(root and root.."/oasis-mod-agent/files/usr/bin/oasis_agent_setup" or "/usr/bin/oasis_agent_setup"))
        local exit={}
        env.code=0
        setfenv(entry,setmetatable({arg=args, require=function(name) return assert(modules[name],name) end,
            os={exit=function(code) env.code=code;error(exit,0) end},
            io={stderr={write=function(_,message) env.error=message end}},
        },{__index=_G}))
        local ok,err=pcall(entry)
        if not ok and err~=exit then error(err) end
        return env.code
    end
    return env
end
function M.register(h)
    h:test("unit","Agent first boot is idempotent and refresh reapplies restored registrations",function(t)
        local e=fixture(t)
        t:assert_equal(0,e.run({"init"}))
        t:assert_equal(0,e.applies)
        t:assert_equal(0,e.run({"refresh","9"}))
        t:assert_equal(1,e.applies)
        t:assert_equal(10,e.generation)
        t:assert_equal("1",e.mode)
        t:assert_true(e.selected)
        t:assert_true(e.marker)
    end)
    h:test("unit","Agent install refreshes even with an old marker and preserves selections",function(t)
        local e=fixture(t)
        t:assert_equal(0,e.run({"initialize-package"}))
        t:assert_equal(1,e.applies)
        t:assert_equal(1,e.invalidations)
        t:assert_true(e.selected)
        t:assert_equal("1",e.sections.manual.enable)
    end)
    h:test("unit","Agent removal returns to Normal and cleans only its own state and exact legacy bindings",function(t)
        local e=fixture(t)
        t:assert_equal(0,e.run({"remove"}))
        t:assert_equal("0",e.mode)
        t:assert_nil(e.sections.owned)
        t:assert_nil(e.sections.legacy)
        t:assert_type("table",e.sections.custom)
        t:assert_equal("1",e.sections.manual.enable)
        t:assert_false(e.selected)
        t:assert_false(e.marker)
        t:assert_equal(0,e.run({"remove"}))
    end)
    h:test("unit","Agent setup failure is reported and does not mark a partial install complete",function(t)
        for _,key in ipairs({"fail_apply","fail_invalidate"}) do
            local e=fixture(t);e.marker=false;e[key]=true
            t:assert_equal(1,e.run({"initialize-package"}))
            t:assert_false(e.marker)
        end
        local e=fixture(t);e.fail_mode=true
        t:assert_equal(1,e.run({"remove"}))
        t:assert_true(e.marker)
        t:assert_true(e.selected)
        t:assert_type("table",e.sections.owned)
    end)
end
return M
