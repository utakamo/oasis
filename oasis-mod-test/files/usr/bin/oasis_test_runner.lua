#!/usr/bin/env lua

local jsonc = require("luci.jsonc")

local function printf(fmt, ...)
    io.write(string.format(fmt, ...))
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil, "open error" end
    local d = f:read("*a")
    f:close()
    return d
end

local function write_file(path, data)
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(data)
    f:close()
    return true
end

local function usage()
    print("Usage: oasis_test_runner.lua [-c config] [--dry-run] [--verbose]")
end

local function parse_argv(argv)
    local opt = { config = "/etc/oasis/oasis-test.conf", dry = false, verbose = false }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "-c" or a == "--config" then
            opt.config = argv[i + 1]
            i = i + 2
        elseif a == "--dry-run" then
            opt.dry = true
            i = i + 1
        elseif a == "-v" or a == "--verbose" then
            opt.verbose = true
            i = i + 1
        elseif a == "-h" or a == "--help" then
            usage()
            os.exit(0)
        else
            printf("Unknown option: %s\n", tostring(a))
            os.exit(1)
        end
    end
    return opt
end

local function to_route_value(route)
    if not route then return nil end
    route = tostring(route):lower()
    if route == "1" or route == "ubus" then return "1" end
    if route == "2" or route == "cli" then return "2" end
    if route == "3" or route == "local" then return "3" end
    return nil
end

local function flush_case(buf, cur)
    if (not cur.route) or (not cur.key) then return end
    local rv = to_route_value(cur.route)
    if not rv then return end
    buf[#buf + 1] = rv .. "\n"       -- route select
    buf[#buf + 1] = tostring(cur.key) .. "\n" -- function key
    for _, a in ipairs(cur.args or {}) do
        buf[#buf + 1] = tostring(a) .. "\n"
    end
    buf[#buf + 1] = "b\n"            -- back to route menu
end

local function unescape_arg(s)
    s = tostring(s)
    s = s:gsub("\\n", "\n")
    s = s:gsub("\\t", "\t")
    s = s:gsub("\\r", "\r")
    s = s:gsub("\\\\", "\\")
    return s
end

local function parse_config(path, verbose)
    local content, err = read_file(path)
    if not content then
        error("Config not found: " .. path .. " (" .. tostring(err) .. ")")
    end
    local buf = {}
    local cur = { route = nil, key = nil, args = {} }
    for line in string.gmatch(content .. "\n", "([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if line:match("^#") then
            -- skip
        elseif line == "" then
            flush_case(buf, cur)
            cur = { route = nil, key = nil, args = {} }
        elseif line:match("^route=") then
            cur.route = line:sub(7)
        elseif line:match("^key=") then
            cur.key = line:sub(5)
        elseif line:match("^arg=") then
            cur.args[#cur.args + 1] = unescape_arg(line:sub(5))
        else
            if verbose then printf("[warn] unknown line: %s\n", line) end
        end
    end
    -- flush last case even if file does not end with a blank line
    flush_case(buf, cur)
    -- ensure quit at end
    buf[#buf + 1] = "q\n"
    return table.concat(buf)
end

local function main()
    local opt = parse_argv(arg)
    local lua_main = "/usr/lib/lua/oasis/test/main.lua"

    local input = parse_config(opt.config, opt.verbose)

    -- check main.lua existence
    do
        local f = io.open(lua_main, "r")
        if not f then
            error("Lua test script not found: " .. lua_main)
        end
        f:close()
    end

    if opt.dry then
        print("----- Generated Input -----")
        io.write(input)
        print("---------------------------")
        return
    end

    local tmp = os.tmpname()
    local ok, werr = write_file(tmp, input)
    if not ok then
        error("Failed to write temp input: " .. tostring(werr))
    end

    local cmd = string.format("/usr/bin/lua %q < %q", lua_main, tmp)
    if opt.verbose then printf("[exec] %s\n", cmd) end
    local code = os.execute(cmd)
    if type(code) == "number" and code ~= 0 then
        error("runner: main.lua exited with code " .. tostring(code))
    end
    os.remove(tmp)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    io.stderr:write(tostring(err) .. "\n")
    os.exit(1)
end
