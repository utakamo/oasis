-- local uci = require("luci.model.uci").cursor()
local misc = require("oasis.chat.misc")
local debug = require("oasis.chat.debug")

local LUA                       = {}
LUA.TYPE                        = {}
LUA.TYPE.NIL                    = "nil"
LUA.TYPE.BOOLEAN                = "boolean"
LUA.TYPE.NUMBER                 = "number"
LUA.TYPE.STRING                 = "string"
LUA.TYPE.FUNCTION               = "function"
LUA.TYPE.USERDATA               = "userdata"
LUA.TYPE.TABLE                  = "table"
LUA.TYPE.THREAD                 = "thread"

local PHASE                     = {}
PHASE.NONE                      = "NONE"
PHASE.A                         = "PHASE_A"
PHASE.B                         = "PHASE_B"
PHASE.C                         = "PHASE_C"
PHASE.D                         = "PHASE_D"
PHASE.E                         = "PHASE_E"
PHASE.F                         = "PHASE_F"
PHASE.G                         = "PHASE_G"
PHASE.H                         = "PHASE_H"
PHASE.I                         = "PHASE_I"
PHASE.J                         = "PHASE_J"
PHASE.K                         = "PHASE_K"
PHASE.L                         = "PHASE_L"
PHASE.M                         = "PHASE_M"
PHASE.N                         = "PHASE_N"
PHASE.O                         = "PHASE_O"
PHASE.P                         = "PHASE_P"
PHASE.Q                         = "PHASE_Q"
PHASE.R                         = "PHASE_R"
PHASE.S                         = "PHASE_S"
PHASE.T                         = "PHASE_T"
PHASE.U                         = "PHASE_U"
PHASE.V                         = "PHASE_V"
PHASE.W                         = "PHASE_W"
PHASE.X                         = "PHASE_X"
PHASE.Y                         = "PHASE_Y"
PHASE.Z                         = "PHASE_Z"

local db                        = {}
db.func                         = {}
db.func.type                    = {}
db.func.behavior                = {}
db.func.type.lua                = {}
db.func.type.c                  = {}
db.func.type.lua.code           = "luacode"
db.func.type.lua.script         = "luascript"
db.func.type.c.code             = "ccode"
db.func.behavior.detecter       = "detecter"
db.func.behavior.action         = "action"

db.phase                        = {}
db.phase.type                   = {}
db.phase.behavior               = {}
db.phase.type.code              = "code"
db.phase.type.script            = "script"
db.phase.behavior.event         = "event"
db.phase.behavior.action        = "action"

db.list                         = {}
db.list.param                   = {}
db.list.param.name              = {}
db.list.param.name.type         = "type"
db.list.param.name.call         = "call"
db.list.param.name.cmdline      = "cmdline"
db.list.param.name.args         = "args"
db.list.param.name.script       = "script"

db.define                       = {}
db.define.param                 = {}
db.define.param.name            = {}
db.define.param.name.behavior   = "behavior"
db.define.param.name.type       = "type"
db.define.param.name.cmdline    = "cmdline"
db.define.param.name.name       = "name"

db.uci                          = {}
db.uci.config                   = "spring"
db.uci.sect                     = {}
db.uci.type                     = {}
db.uci.opt                      = {}
db.uci.type.master              = {}
db.uci.type.master.event        = "master-event-func"
db.uci.type.master.action       = "master-action-func"
db.uci.opt.func                 = "func"
db.uci.opt.args                 = "args"

-------------------------------
-- Function Defines  [START] --

local retrieve_phase_base_tbl = function(uci_sect_type)
    -- local phase_base_tbl = uci:get_all(db.uci.config, '@' .. uci_sect_type .. '[0]')
    -- return phase_base_tbl
    return uci_sect_type
end

-- register master func list --
local register_luacode_event_detecter_func = function(defines, cmdline, name, event_detecter_func)
     defines[#defines + 1]        = {}
     defines[#defines].behavior   = db.func.behavior.detecter
     defines[#defines].type       = db.func.type.lua.code
     defines[#defines].cmdline    = cmdline
     defines[#defines].name       = {}
     defines[#defines].name[name] = event_detecter_func
end

local register_luacode_action_func = function(defines, cmdline, name, action_func)
     defines[#defines + 1]        = {}
     defines[#defines].behavior   = db.func.behavior.action
     defines[#defines].type       = db.func.type.lua.code
     defines[#defines].cmdline    = cmdline
     defines[#defines].name       = {}
     defines[#defines].name[name] = action_func
end

-- register master func list --
local register_ccode_event_detecter_func = function(defines, cmdline, name)

    if not _G[name] then
        debug:log("spring-error.log", "[Event] Failed to add \"" .. name .. "\" func")
        return
    end

     defines[#defines + 1]        = {}
     defines[#defines].behavior   = db.func.behavior.detecter
     defines[#defines].type       = db.func.type.c.code
     defines[#defines].cmdline    = cmdline
     defines[#defines].name       = {}
     defines[#defines].name[name] = _G[name]
end

local register_ccode_action_func = function(defines, cmdline, name)

    if not _G[name] then
        debug:log("spring-error.log", "[Action] Failed to add \"" .. name .. "\" func")
        return
    end

    defines[#defines + 1]        = {}
    defines[#defines].behavior   = db.func.behavior.action
    defines[#defines].type       = db.func.type.c.code
    defines[#defines].cmdline    = cmdline
    defines[#defines].name       = {}
    defines[#defines].name[name] = _G[name]
end

-- Define func process
local create_phase = function(defines, event_base_tbl, action_base_tbl, interval)

    local target_phase_func_list = {}
    target_phase_func_list.interval = interval
    target_phase_func_list.event    = {}
    target_phase_func_list.action   = {}

    local register_function_into_list = function(list, df, inf, bvr)
        for idx, _ in ipairs(inf) do
            local defidx = 0
            if inf[idx].type == db.func.type.lua.code then
                for index, target_func in ipairs(df) do
                    for func, _ in pairs(target_func.name) do
                        if inf[idx].name == func then
                            -- print("func = " .. func)
                            defidx = index
                            break
                        end
                    end
                    if defidx > 0 then
                        break
                    end
                end

                if defidx > 0 then
                    list[bvr][#list[bvr] + 1] = {}
                    list[bvr][#list[bvr]][db.list.param.name.type] = db.phase.type.code
                    list[bvr][#list[bvr]][db.list.param.name.call] = df[defidx][db.define.param.name.name][inf[idx].name]
                    list[bvr][#list[bvr]][db.list.param.name.cmdline] = df[defidx][db.define.param.name.cmdline]
                    list[bvr][#list[bvr]][db.list.param.name.args] = inf[idx].args
                end

            elseif inf[idx].type == db.func.type.lua.script then
                    list[bvr][#list[bvr] + 1] = {}
                    list[bvr][#list[bvr]][db.list.param.name.type] = db.phase.type.script
                    list[bvr][#list[bvr]][db.list.param.name.call] = function(script)
                    -- Todo: check file exist
                    local result = dofile(script)
                    return result
                end
                list[bvr][#list[bvr]][db.list.param.name.script] = inf[idx].name
            end
        end
    end

    register_function_into_list(target_phase_func_list, defines, event_base_tbl, db.phase.behavior.event)
    register_function_into_list(target_phase_func_list, defines, action_base_tbl, db.phase.behavior.action)

    return target_phase_func_list
end

-- Execute func Process
local execute_phase = function(target_phase_func_list)

    local next_phase = PHASE.NONE

    -- event detect function
    for idx, func in ipairs(target_phase_func_list.event) do

        if misc.check_file_exist("/tmp/spring/terminate") then
            return PHASE.NONE
        end

        if target_phase_func_list.interval then
            os.execute("sleep " .. target_phase_func_list.interval)
        end

        local result
        if func.type == db.phase.type.code then
            if func.cmdline then
                result = func.call(func.args)
            else
                result = func.call()
            end
        elseif func.type == db.phase.type.script then
            result = func.call(func.script)
        end

        -- judge exec action function
        if result then
            -- print("result type = " .. type(result))
            if type(result) == LUA.TYPE.STRING then
                -- local next_phase = target_phase_func_list.action[idx].func.call()
                print(result)
                debug:log("spring-r.log", "value:" .. result)
            elseif type(result) == LUA.TYPE.TABLE then
                for idx, value in pairs(result) do
                    print(idx .. ": " .. value)
                    debug:log("spring-r.log", "key:" .. idx .. ", value:" .. value)
                end
            end
        end

        if next_phase ~= PHASE.NONE then
            break
        end
    end

    return next_phase
end
-----------------------------
-- Function Defines  [END] --
-----------------------------

return {
    retrieve_phase_base_tbl                 = retrieve_phase_base_tbl,
    register_luacode_event_detecter_func    = register_luacode_event_detecter_func,
    register_ccode_event_detecter_func      = register_ccode_event_detecter_func,
    register_luacode_action_func            = register_luacode_action_func,
    register_ccode_action_func              = register_ccode_action_func,
    create_phase                            = create_phase,
    execute_phase                           = execute_phase,
}