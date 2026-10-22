local jsonc = require("luci.jsonc")
local history = require("oasis.chat.history")
local storage = require("oasis.chat.storage")
local recorder = require("oasis.chat.recorder")
local M = {}

local function fixture(t)
    local fs = require("nixio.fs")
    local directory = "/tmp/oasis-history-test-" .. storage.new_id()
    assert(fs.mkdir(directory, "700"))
    local originals, sections, serial = {}, {}, 0
    local function replace(name, value)
        if originals[name] == nil then originals[name]={package.loaded[name]} end
        package.loaded[name]=value
    end
    t:on_cleanup(function()
        for name, previous in pairs(originals) do package.loaded[name]=previous[1] end
        for name in fs.dir(directory) do os.remove(directory .. "/" .. name) end
        fs.rmdir(directory)
    end)
    local common=history.copy(require("oasis.common"))
    common.generate_chat_id=function() serial=serial+1; return tostring(700000+serial) end
    common.search_chat_id=function(id)
        for _,item in pairs(sections) do if item.id==id then return true end end
        return false
    end
    replace("oasis.common",common)
    local cursor={
        foreach=function(_,_,_,fn) for _,item in pairs(sections) do fn(item) end end,
        add=function() local key="s" .. storage.new_id(); sections[key]={[".name"]=key}; return key end,
        set=function(_,_,key,option,value) sections[key][option]=value; return true end,
        delete=function(_,_,key) sections[key]=nil; return true end,
        commit=function() return true end,
        get_bool=function() return true end,
        get=function() return nil end,
        get_all=function() return {} end,
    }
    replace("luci.model.uci",{cursor=function() return cursor end})
    replace("oasis.chat.datactrl",{get_ai_service_cfg=function() return {path=directory,prefix="chat-"} end})
    replace("oasis.chat.debug",{log=function() end,dump=function() end})
    local env={directory=directory, replace=replace, executions=0, schema={
        {name="inspect",description="CURRENT_DEFINITION",parameters={type="object",properties={}}}
    }}
    replace("oasis.local.tool.client",{
        get_function_call_schema=function() return env.schema end,
        exec_server_tool=function(_,name,args)
            env.executions=env.executions+1
            if env.throw_at==env.executions then error("fixture tool interrupted") end
            if env.fail_at==env.executions then
                return {status="ERROR",error="fixture refusal",user_only="PRIVATE_FAILURE"}
            end
            if name=="set_tool_enabled" then
                env.schema[2]={name="inspect",description="ENABLED_DURING_TURN",
                    parameters={type="object",properties={}}}
            end
            return {status="OK",value=args.value,user_only="PRIVATE_RESULT",
                ui_action={type="fixture"}}
        end,
    })
    function env:load(id)
        local file=assert(io.open(directory .. "/chat-" .. id,"r"))
        local raw=file:read("*a"); file:close()
        local doc,err=history.decode(raw)
        assert(doc,err)
        return doc,raw
    end
    function env:service(module)
        replace("oasis.chat.function.calling." .. module,nil)
        replace("oasis.chat.service." .. module,nil)
        local service=require("oasis.chat.service." .. module)
        service.cfg={service=module,model="fixture-model",function_calling="1",max_tokens=1024,show_thinking="0"}
        service.format="chat"
        return service
    end
    function env:rpc(method,payload)
        local raw=jsonc.stringify(payload,false)
        local result
        local script=loadfile("./oasis/files/usr/libexec/rpcd/oasis.chat") or assert(loadfile("/usr/libexec/rpcd/oasis.chat"))
        local sandbox=setmetatable({arg={"call",method},
            io=setmetatable({read=function() local chunk=raw;raw=nil;return chunk end},{__index=io}),
            os=setmetatable({exit=function(code) if code~=0 then error("rpc rejected input") end end},{__index=os}),
            print=function(value) result=jsonc.parse(value) end,
        },{__index=_G})
        setfenv(script,sandbox)()
        return result
    end
    return env
end

local function chat()
    return {model="fixture-model",messages={{role="system",content="fixture system"},{role="user",content="inspect"}}}
end

local providers={"openai","ollama","openai_responses","anthropic","gemini"}
local function invoke(name,service,count,without_id)
    local calls={}
    for index=1,count do
        local id="call-" .. index
        local args={value=index}
        if name=="openai" or name=="ollama" then
            calls[index]={id=not without_id and id or nil,type="function",
                ["function"]={name="inspect",arguments=jsonc.stringify(args,false)}}
        elseif name=="openai_responses" then calls[index]={call_id=id,name="inspect",arguments=jsonc.stringify(args,false)}
        elseif name=="anthropic" then calls[index]={id=id,name="inspect",input=args}
        else calls[index]={id=id,provider_id=not without_id and ("provider-"..id) or nil,name="inspect",args=args} end
    end
    service._request_tools_enabled=true
    service._request_tool_names={inspect=true}
    service._request_tool_choice=name=="gemini" and "AUTO" or "auto"
    local adapter=require("oasis.chat.function.calling." .. name)
    if name=="openai" or name=="ollama" then
        return adapter.process(service,{role="assistant",content="Inspecting now",tool_calls=calls})
    end
    service._answer_text="Inspecting now"
    service._answer_delta_buffer="Inspecting now"
    return adapter.process(service,calls)
end

function M.register(harness)
    harness:test("unit","history validates associations and preserves exact JSON snapshots",function(t)
        local body='{"messages":[{"content":"tools, \\" quoted"}],"tools":[{"parameters":{"a":{},"b":[]}}],"tool_choice":"auto"}'
        t:assert_equal('[{"parameters":{"a":{},"b":[]}}]',history.json_field(body,"tools"))
        t:assert_equal('"auto"',history.json_field(body,"tool_choice"))
        t:assert_nil(history.decode('{"format_version":99,"messages":[]}'))
        t:assert_nil(history.decode(string.rep('[',49)..string.rep(']',49)))
        t:assert_nil(history.decode('{"format_version":2,"messages":[],"turns":[{}]}'))
    end)

    harness:test("unit","history storage checkpoints are atomic idempotent and revision checked",function(t)
        local env=fixture(t)
        local doc=history.upgrade(chat())
        local created=storage.create(doc,"710000","operation-1")
        t:assert_equal("OK",created.status,created.desc)
        local duplicate=storage.create(doc,"710000","operation-1")
        t:assert_true(duplicate.duplicate)
        doc.messages[2].content="changed"
        t:assert_equal("ERROR",storage.create(doc,"710000","operation-1").status)
        t:assert_equal("ERROR",storage.save("710000",doc,"operation-2",false).status)
        doc=env:load("710000")
        local previous=select(2,env:load("710000"))
        local original=storage.write_atomic
        t:on_cleanup(function() storage.write_atomic=original end)
        storage.write_atomic=function() return nil,"No space left on device" end
        doc.messages[#doc.messages+1]={role="assistant",content="new"}
        local failed=storage.save("710000",doc,"operation-3",false)
        t:assert_equal("ERROR",failed.status)
        t:assert_contains(failed.desc,"No space")
        t:assert_equal(previous,select(2,env:load("710000")))
        storage.write_atomic=original
        t:assert_equal("OK",storage.save("710000",doc,"operation-3",false).status)
        t:assert_true(storage.save("710000",doc,"operation-3",false).duplicate)
        t:assert_equal("OK",storage.delete("710000").status)
        t:assert_nil(io.open(env.directory .. "/chat-710000","r"))
    end)

    harness:test("unit","history no-tool turns preserve offered definitions and exclude them for every provider",function(t)
        local env=fixture(t)
        local service=env:service("openai")
        local live=chat()
        recorder.start(service,live)
        local id=service.cfg.id
        local body=service:convert_schema(live)
        recorder.request(service,body)
        recorder.response(service,{message="answer"})
        live.messages[#live.messages+1]={role="assistant",content="answer"}
        recorder.complete(service,live)
        recorder.finish(service,{ok=true})
        local saved=env:load(id)
        t:assert_equal("provided",saved.turns[1].requests[1].tools.state)
        t:assert_equal(0,#saved.turns[1].requests[1].calls)
        local invalid=history.copy(saved)
        invalid.turns[1].requests[1].tools.definitions_json=string.rep('[',49)..string.rep(']',49)
        t:assert_nil(history.decode(jsonc.stringify(invalid,false)))
        saved.turns[1].requests[1].tools.definitions_json='[{"description":"OLD_PRIVATE_SCHEMA","parameters":{"OLD_ARGUMENT":{}}}]'
        env.schema[1].description="NEW_DEFINITION"
        for _,name in ipairs({"openai","ollama","openai_responses","anthropic","gemini","lmstudio"}) do
            local provider=env:service(name)
            local outgoing=provider:convert_schema(saved)
            t:assert_not_contains(outgoing,"OLD_PRIVATE_SCHEMA",name)
            t:assert_not_contains(outgoing,"OLD_ARGUMENT",name)
            t:assert_not_contains(outgoing,"format_version",name)
            if name~="lmstudio" then t:assert_contains(outgoing,"NEW_DEFINITION",name) end
            provider.cfg.function_calling="0"
            outgoing=provider:convert_schema(saved)
            t:assert_not_contains(outgoing,"NEW_DEFINITION",name)
            t:assert_not_contains(outgoing,"OLD_PRIVATE_SCHEMA",name)
        end
        local imported=storage.import(jsonc.stringify(saved,false))
        t:assert_equal("OK",imported.status,imported.desc)
        local roundtrip=env:load(imported.id)
        t:assert_equal(saved.turns[1].requests[1].tools.definitions_json,roundtrip.turns[1].requests[1].tools.definitions_json)
        t:assert_equal(0,env.executions)
    end)

    for _,provider in ipairs(providers) do
        local name=provider
        harness:test("unit","history records ordered calls and private results for "..name,function(t)
            local env=fixture(t)
            local service=env:service(name)
            local live=chat()
            recorder.start(service,live)
            recorder.request(service,service:convert_schema(live))
            local _,_,speaker,used,err=invoke(name,service,2,name=="ollama" or name=="gemini")
            t:assert_nil(err)
            t:assert_true(used)
            recorder.response(service,speaker)
            local saved=env:load(service.cfg.id)
            local calls=saved.turns[1].requests[1].calls
            t:assert_equal(2,#calls)
            for index,call in ipairs(calls) do
                t:assert_equal(index,jsonc.parse(call.arguments_json).value)
                t:assert_equal("completed",call.status)
                t:assert_equal("success",call.result.status)
                t:assert_contains(call.result.original_json,"PRIVATE_RESULT")
                t:assert_not_contains(call.result.ai_json,"PRIVATE_RESULT")
                t:assert_not_contains(call.result.ai_json,"ui_action")
                if name=="ollama" or name=="gemini" then t:assert_nil(call.provider_id) end
            end
            t:assert_true(calls[1].id~=calls[2].id)
            t:assert_equal("Inspecting now",saved.turns[1].requests[1].assistant_text)
            recorder.request(service,'{"messages":[]}')
            local failed=recorder.finish(service,{ok=false,message="network failed",error={message="network failed"}})
            t:assert_equal(service.cfg.id,failed.error.chat_id)
            saved=env:load(service.cfg.id)
            t:assert_not_contains(service:convert_schema(saved),"PRIVATE_RESULT")
            t:assert_equal(2,#saved.turns[1].requests)
            t:assert_equal("none",saved.turns[1].requests[2].tools.state)
            t:assert_equal("failed",saved.turns[1].requests[2].status)
            t:assert_equal(2,env.executions)
            local imported=storage.import(jsonc.stringify(saved,false))
            local restored=env:load(imported.id)
            t:assert_equal(calls[1].id,restored.turns[1].requests[1].calls[1].id)
            t:assert_equal(calls[1].result.original_json,restored.turns[1].requests[1].calls[1].result.original_json)
        end)
    end

    harness:test("unit","history persists a partial batch before a later tool throws",function(t)
        local env=fixture(t)
        local service=env:service("openai")
        recorder.start(service,chat())
        recorder.request(service,service:convert_schema(chat()))
        env.throw_at=2
        t:assert_false(pcall(invoke,"openai",service,3))
        local saved=env:load(service.cfg.id)
        local calls=saved.turns[1].requests[1].calls
        t:assert_equal("completed",calls[1].status)
        t:assert_equal("failed",calls[2].status)
        t:assert_equal("pending",calls[3].status)
        t:assert_nil(calls[3].result)
        t:assert_equal(2,env.executions)
    end)

    harness:test("unit","history retains explicit tool failures without labelling them successful",function(t)
        local env=fixture(t)
        local service=env:service("openai")
        recorder.start(service,chat())
        recorder.request(service,service:convert_schema(chat()))
        env.fail_at=2
        invoke("openai",service,2)
        local calls=env:load(service.cfg.id).turns[1].requests[1].calls
        t:assert_equal("completed",calls[1].status)
        t:assert_equal("failed",calls[2].status)
        t:assert_equal("error",calls[2].result.status)
        t:assert_contains(calls[2].result.original_json,"PRIVATE_FAILURE")
        t:assert_not_contains(calls[2].result.ai_json,"PRIVATE_FAILURE")
        t:assert_contains(calls[2].result.ai_json,"fixture refusal")
    end)

    harness:test("unit","history checkpoints survive a process exiting during a tool",function(t)
        local env=fixture(t)
        local service=env:service("openai")
        recorder.start(service,chat())
        recorder.request(service,service:convert_schema(chat()))
        local calls={{id="first",name="inspect",normalized_args="{}"},
            {id="second",name="inspect",normalized_args="{}"}}
        recorder.calls(service,calls,"Inspecting now")
        local nixio=require("nixio")
        local pid=assert(nixio.fork())
        if pid==0 then
            recorder.execute(service,calls[1],function() os.exit(0) end)
            os.exit(1)
        end
        local child,reason,code=nixio.waitpid(pid)
        t:assert_equal(pid,child)
        t:assert_equal("exited",reason)
        t:assert_equal(0,code)
        local saved=env:load(service.cfg.id)
        t:assert_equal("incomplete",saved.turns[1].status)
        t:assert_equal("running",saved.turns[1].requests[1].calls[1].status)
        t:assert_equal("pending",saved.turns[1].requests[1].calls[2].status)
        t:assert_nil(saved.turns[1].requests[1].calls[1].result)
    end)

    harness:test("unit","history save failure stops remaining tools and cannot replay completed tools",function(t)
        local env=fixture(t)
        local service=env:service("openai")
        recorder.start(service,chat())
        recorder.request(service,service:convert_schema(chat()))
        local original=storage.write_atomic
        t:on_cleanup(function() storage.write_atomic=original end)
        storage.write_atomic=function(path,raw)
            if env.executions>0 then return nil,"No space left on device" end
            return original(path,raw)
        end
        t:assert_false(pcall(invoke,"openai",service,2))
        t:assert_equal(1,env.executions)
        local result=recorder.finish(service,{ok=false,error={},message="save failed"})
        t:assert_equal("storage_error",result.error.kind)
        t:assert_false(result.error.can_continue)
        local saved=env:load(service.cfg.id)
        t:assert_equal("running",saved.turns[1].requests[1].calls[1].status)
        t:assert_nil(saved.turns[1].requests[1].calls[1].result)
    end)

    harness:test("unit","history legacy import and append migrate without parity assumptions",function(t)
        local env=fixture(t)
        local imported=storage.import('{"messages":[{"role":"user","content":"old"},{"role":"assistant","content":"reply"}]}')
        t:assert_equal("OK",imported.status,imported.desc)
        local appended=storage.legacy_append(imported.id,{{role="user",content="next"},{role="assistant",content="next answer"}})
        t:assert_equal("OK",appended.status,appended.desc)
        local doc=env:load(imported.id)
        t:assert_equal(4,#doc.messages)
        t:assert_equal(0,#doc.turns)
        local provider=env:service("ollama")
        provider.cfg.id=imported.id
        doc.messages[#doc.messages+1]={role="user",content="new turn"}
        recorder.start(provider,doc)
        recorder.request(provider,'{"messages":[]}')
        recorder.response(provider,{message="new answer"})
        doc.messages[#doc.messages+1]={role="assistant",content="new answer"}
        recorder.complete(provider,doc)
        local saved=env:load(imported.id)
        t:assert_equal(6,#saved.messages)
        t:assert_equal(5,saved.turns[1].user_message)
    end)

    harness:test("unit","history RPC preserves legacy calls and accepts structured checkpoints",function(t)
        local env=fixture(t)
        local created=env:rpc("create",{role1="user",content1="old",role2="assistant",content2="answer",role3="",content3=""})
        t:assert_equal("OK",created.status,created.desc)
        local args={id=created.id,role1="user",content1="next",role2="assistant",content2="next answer",operation_id="legacy-append"}
        t:assert_equal("OK",env:rpc("append",args).status)
        t:assert_true(env:rpc("append",args).duplicate)
        local loaded=env:rpc("load",{id=created.id})
        t:assert_equal(4,#loaded.messages)
        loaded.messages[#loaded.messages+1]={role="user",content="interrupted"}
        local snapshot={id=created.id,data=jsonc.stringify(loaded,false),operation_id="checkpoint"}
        t:assert_equal("OK",env:rpc("append",snapshot).status)
        t:assert_true(env:rpc("append",snapshot).duplicate)
        snapshot.operation_id="stale"
        t:assert_equal("ERROR",env:rpc("append",snapshot).status)
        t:assert_equal("OK",env:rpc("delete",{id=created.id}).status)
        t:assert_equal("NOT FOUND",env:rpc("delete",{id=created.id}).status)
        local doc=history.upgrade(chat())
        local new={id="720000",data=jsonc.stringify(doc,false),operation_id="structured-create"}
        t:assert_equal("OK",env:rpc("create",new).status)
        t:assert_true(env:rpc("create",new).duplicate)
        new.data='{"format_version":2,"messages":[],"turns":[{}]}'
        t:assert_equal("ERROR",env:rpc("create",new).status)
    end)

    for _,mode in ipairs({"chat","output","rpc_output"}) do
        local format=mode
        harness:test("unit","history shared transfer persists new and continued "..format.." turns",function(t)
            local env=fixture(t)
            local service=env:service("openai")
            service.format=package.loaded["oasis.common"].ai.format[format]
            local common=package.loaded["oasis.common"]
            common.ubus_call=function() return {status="OK",title="Fixture"} end
            env.replace("oasis.local.tool.state",{
                TOOL_SEARCH_ABI=2,
                set_auto_enabled=function() end,
                is_control_tool=function(server,name) return server=="oasis.tool.manager" and name=="set_tool_enabled" end,
                list_effective=function() return {status="OK",tool={{server="oasis.tool.manager",name="set_tool_enabled",enabled=true,conflicted=false}}} end,
            })
            env.schema={{name="set_tool_enabled",description="Enable tool",parameters={type="object",properties={}}}}
            env.replace("oasis.console",{write=function() end,flush=function() end})
            local schema=history.copy(require("oasis.unified.chat.schema"))
            schema.setup_system_msg=function() end
            schema.with_auto_tool_search_prompt=function(_,value) return value end
            env.replace("oasis.unified.chat.schema",schema)
            env.replace("oasis.chat.transfer",nil)
            env.replace("oasis.chat.tool_sequence",nil)
            local transfer=require("oasis.chat.transfer")
            local outbound={}
            transfer.post_to_server=function(_,body,callback)
                outbound[#outbound+1]=body
                local round=(#outbound-1)%3+1
                if round==3 then
                    if env.fail_followup then return {kind="network_error",message="fixture network failure"} end
                    callback('{"choices":[{"message":{"role":"assistant","content":"fixture answer"}}]}')
                else
                    local calls={}
                    for index=1,(round==1 and 1 or 2) do
                        calls[index]={id="call-"..#outbound.."-"..index,type="function",["function"]={
                            name=round==1 and "set_tool_enabled" or "inspect",
                            arguments=jsonc.stringify(round==1 and {server="fixture",tool="inspect"} or {value=index},false)}}
                    end
                    callback(jsonc.stringify({choices={{message={role="assistant",content="Inspecting now",tool_calls=calls}}}},false))
                end
            end
            local runner=require("oasis.chat.tool_sequence")
            local live=chat()
            local result=runner.run(service,live)
            t:assert_true(result.ok,result.message)
            t:assert_type("string",result.new_chat_info)
            local id=service.cfg.id
            local first=env:load(id)
            t:assert_equal(3,#first.messages)
            t:assert_equal(3,#first.turns[1].requests)
            t:assert_not_contains(first.turns[1].requests[1].tools.definitions_json,"ENABLED_DURING_TURN")
            t:assert_contains(first.turns[1].requests[2].tools.definitions_json,"ENABLED_DURING_TURN")
            t:assert_equal("none",first.turns[1].requests[3].tools.state)
            t:assert_equal(2,#first.turns[1].requests[2].calls)
            for _,body in ipairs(outbound) do t:assert_not_contains(body,"PRIVATE_RESULT") end
            t:assert_contains(outbound[3],"tool_call_id")
            live.messages[#live.messages+1]={role="user",content="continue"}
            result=runner.run(service,live)
            t:assert_true(result.ok,result.message)
            local saved=env:load(id)
            t:assert_equal(5,#saved.messages)
            t:assert_equal(2,#saved.turns)
            t:assert_not_contains(outbound[4],"format_version")
            t:assert_not_contains(outbound[4],"requests")
            t:assert_not_contains(outbound[4],"call-1-1")
            t:assert_equal(6,env.executions)
            -- A new conversation remains findable even without a final answer.
            service.cfg.id=nil
            env.fail_followup=true
            result=runner.run(service,chat())
            t:assert_false(result.ok)
            t:assert_equal(service.cfg.id,result.error.chat_id)
            t:assert_false(result.error.can_continue)
            local failed=env:load(service.cfg.id)
            t:assert_equal(2,#failed.messages)
            t:assert_equal("failed",failed.turns[1].status)
            t:assert_equal("completed",failed.turns[1].requests[2].calls[2].status)
            t:assert_equal("failed",failed.turns[1].requests[3].status)
        end)
    end
end

return M
