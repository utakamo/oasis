#!/usr/bin/env lua

local jsonc = require("luci.jsonc")

local methods = {
    get_tool_info = {
        call = function()
            local r = {}
            return r
        end
    },

    set_tool_enabled = {
        call = function()
            local r = {}
            return r
        end
    },

    set_tool_disabled = {
        call = function()
            local r = {}
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
