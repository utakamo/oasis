#!/usr/bin/env lua

local jsonc = require("luci.jsonc")

local methods = {}

local add_tool = function(func_name, def)
    methods[func_name] = def
end

local response = function(tbl)
    local r = {}
    r.result = jsonc.stringify(tbl)
    return r
end

local parseInput = function()
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

local validateArgs = function(func, uargs)
    local tool = methods[func]
    if not tool then
        print(jsonc.stringify({error = "Tool not found in methods table"}))
        os.exit(1)
    end
    local n = 0
    for _, _ in pairs(uargs) do n = n + 1 end
    if tool.args and n == 0 then
        print(jsonc.stringify({
            error = "Received empty arguments for " .. func ..
                " but it requires " .. jsonc.stringify(tool.args)
        }))
        os.exit(1)
    end
    uargs.ubus_rpc_session = nil
    local margs = tool.args or {}
    for k, v in pairs(uargs) do
        if margs[k] == nil or (v ~= nil and type(v) ~= type(margs[k])) then
            print(jsonc.stringify({
                error = "Invalid argument '" .. k .. "' for " .. func ..
                    " it requires " .. jsonc.stringify(tool.args)
            }))
            os.exit(1)
        end
    end
    return tool
end

local activate_tools = function(arg)
    -- Export call_<tool> functions for ubus/rpcd compatibility
    for name, def in pairs(methods) do
        _G["call_" .. name] = function(session, args)
            args = args or {}
            local ok, res = pcall(def.call, args)
            if ok then
                return res
            else
                return { error = tostring(res) }
            end
        end
    end

    if arg[1] == "list" then
        local _, rv = nil, {}
        for _, tool in pairs(methods) do rv[_] = tool.args or {} end
        print((jsonc.stringify(rv):gsub(":%[%]", ":{}")))
    elseif arg[1] == "meta" then
        local _, rv = nil, {}
        for name, tool in pairs(methods) do
            rv[name] = {
                args = tool.args or {},
                args_desc = tool.args_desc or {},
                tool_desc = tool.tool_desc or ""
            }
        end
        print((jsonc.stringify(rv):gsub(":%[%]", ":{}")))
    elseif arg[1] == "call" then
        local args = parseInput()
        local tool = validateArgs(arg[2], args)
        local run = tool.call(args)
        print(run.result)
        os.exit(run.code or 0)
    end
end

return {
    add_tool = add_tool,
    response = response,
    parseInput = parseInput,
    validateArgs = validateArgs,
    activate_tools = activate_tools,
}
