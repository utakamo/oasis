#!/usr/bin/env lua

local jsonc = require("luci.jsonc")

local methods = {
    get_tool_info = {
        call = function()
            local debug = require("oasis.chat.debug")
            local uci = require("luci.model.uci").cursor()
            local jsonc = require("luci.jsonc")
            local tool = {}

            local info = uci:get_all("oasis")

            for _, target in pairs(info) do
                if (target[".type"] == "tool")  then
                    tool[#tool + 1] = {
                        server = target.server,
                        name   = target.name,
                        enable = target.enable
                    }
                end
            end

            local r = {}
            r.result = jsonc.stringify({ tool = tool })
            return r
        end
    },

    set_tool_enabled = {
        args = { tool = "a_string" },
        call = function(args)
            local uci = require("luci.model.uci").cursor()
            local jsonc = require("luci.jsonc")

            local info = uci:get_all("oasis")
            local is_changed = false

            for sect, _ in pairs(info) do
                local target = info[sect]
                if (target[".type"] == "tool") and (target.name == args.tool) then
                    uci:set("oasis", sect, "enable", 1)
                    uci:commit("oasis")
                    is_changed = true
                    break
                end
            end

            local r = {}
            r.result = jsonc.stringify({status = "NG"})

            if is_changed then
                r.result = jsonc.stringify({status = "OK"})
            end

            return r
        end
    },

    set_tool_disabled = {
        args = { tool = "a_string" },
        call = function(args)
            local uci = require("luci.model.uci").cursor()
            local jsonc = require("luci.jsonc")

            local info = uci:get_all("oasis")
            local is_changed = false

            for sect, _ in pairs(info) do
                local target = info[sect]
                if (target[".type"] == "tool") and (target.name == args.tool) then
                    uci:set("oasis", sect, "enable", 0)
                    uci:commit("oasis")
                    is_changed = true
                    break
                end
            end

            local r = {}
            r.result = jsonc.stringify({status = "NG"})

            if is_changed then
                r.result = jsonc.stringify({status = "OK"})
            end

            return r
        end
    },
}

local function parseInput()

    local parse = jsonc.new()
    local done, err

    while true do
        local chunk = io.read(4096)
        if not chunk then
            break
        elseif not done and not err then
            done, err = parse:parse(chunk)
        end
    end

    if not done then
        print(jsonc.stringify({
            error = err or "Incomplete input for argument parsing"
        }))
        os.exit(1)
    end

    return parse:get()
end

-- validation
local function validateArgs(func, uargs)

    local method = methods[func]
    if not method then
        print(jsonc.stringify({error = "Method not found in methods table"}))
        os.exit(1)
    end

    local n = 0
    for _, _ in pairs(uargs) do n = n + 1 end

    if method.args and n == 0 then
        print(jsonc.stringify({
            error = "Received empty arguments for " .. func ..
                " but it requires " .. jsonc.stringify(method.args)
        }))
        os.exit(1)
    end

    uargs.ubus_rpc_session = nil

    local margs = method.args or {}
    for k, v in pairs(uargs) do
        if margs[k] == nil or (v ~= nil and type(v) ~= type(margs[k])) then
            print(jsonc.stringify({
                error = "Invalid argument '" .. k .. "' for " .. func ..
                    " it requires " .. jsonc.stringify(method.args)
            }))
            os.exit(1)
        end
    end

    return method
end

-- ubus list & call
if arg[1] == "list" then
    local _, rv = nil, {}
    for _, method in pairs(methods) do rv[_] = method.args or {} end
    print((jsonc.stringify(rv):gsub(":%[%]", ":{}")))
elseif arg[1] == "call" then
    local args = parseInput()
    local method = validateArgs(arg[2], args)
    local run = method.call(args)
    print(run.result)
    os.exit(run.code or 0)
end
