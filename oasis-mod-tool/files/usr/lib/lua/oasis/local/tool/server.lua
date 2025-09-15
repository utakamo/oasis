#!/usr/bin/env lua

local jsonc = require("luci.jsonc")

local methods = {}

local tool = function(func_name, def)
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

local run = function(arg)
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
        for _, tl in pairs(methods) do rv[_] = tl.args or {} end
        print((jsonc.stringify(rv):gsub(":%[%]", ":{}")))
    elseif arg[1] == "meta" then
        local _, rv = nil, {}
        for name, tl in pairs(methods) do
            rv[name] = {
                args = tl.args or {},
                args_desc = tl.args_desc or {},
                tool_desc = tl.tool_desc or "",
                exec_msg = tl.exec_msg or "",
                download_msg = tl.download_msg or "",
                timeout = tl.timeout or "",
            }
        end
        print((jsonc.stringify(rv):gsub(":%[%]", ":{}")))
    elseif arg[1] == "call" then
        local args = parseInput()
        local tgt_tool = validateArgs(arg[2], args)
        local run = tgt_tool.call(args)
        print(run.result)
        os.exit(run.code or 0)
    end
end

return {
    tool = tool,
    response = response,
    parseInput = parseInput,
    validateArgs = validateArgs,
    run = run,
}
