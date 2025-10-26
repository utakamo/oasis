local jsonc   = require("luci.jsonc")
local util    = require("luci.util")
local sys     = require("luci.sys")
local misc    = require("oasis.chat.misc")
local common  = require("oasis.common")
local ous     = require("oasis.unified.chat.schema")

local function println(s)
    if s and #tostring(s) > 0 then
        print(s)
    else
        print("")
    end
end

local function pretty(obj)
    if obj == nil then return "(nil)" end
    if type(obj) == "table" then
        local ok, s = pcall(jsonc.stringify, obj, false)
        if ok and s then return s end
    end
    return tostring(obj)
end

local function pretty_or_raw(s)
    if not s or #s == 0 then return "" end
    local ok, parsed = pcall(jsonc.parse, s)
    if ok and parsed then
        local ok2, out = pcall(jsonc.stringify, parsed, false)
        return ok2 and out or s
    end
    return s
end

-- ============ ubus tests ============
local function ubus_list()
    return util.ubus("oasis.chat", "list", {})
end

local function ubus_create(args)
    return util.ubus("oasis.chat", "create", {
        role1 = args.role1, content1 = args.content1,
        role2 = args.role2, content2 = args.content2,
        role3 = args.role3, content3 = args.content3,
    })
end

local function ubus_load(args)
    return util.ubus("oasis.chat", "load", { id = args.id })
end

local function ubus_send(args)
    return util.ubus("oasis.chat", "send", { id = args.id, sysmsg_key = args.sysmsg_key, message = args.message })
end

local function ubus_append(args)
    return util.ubus("oasis.chat", "append", {
        id = args.id,
        role1 = args.role1, content1 = args.content1,
        role2 = args.role2, content2 = args.content2,
    })
end

local function ubus_delete(args)
    return util.ubus("oasis.chat", "delete", { id = args.id })
end

local ubus_menu = {
    { key = "1", title = "oasis.chat list", desc = "List chats", args = {}, run = function()
        local r = ubus_list() or {}
        println(pretty(r))
    end },
    { key = "2", title = "oasis.chat create", desc = "Create new chat", args = {
        {name="role1"},{name="content1"},{name="role2"},{name="content2"},{name="role3"},{name="content3"}
    }, run = function(a)
        local r = ubus_create(a) or {}
        println(pretty(r))
    end },
    { key = "3", title = "oasis.chat load", desc = "Load chat", args = { {name="id"} }, run = function(a)
        local r = ubus_load(a) or {}
        -- 'load' returns a JSON string; print as-is or pretty-parse
        if type(r) == "table" and r.result then
            println(pretty_or_raw(r.result))
        else
            println(pretty(r))
        end
    end },
    { key = "4", title = "oasis.chat send", desc = "Send message", args = {
        {name="id"},{name="sysmsg_key"},{name="message"}
    }, run = function(a)
        local r = ubus_send(a) or {}
        if type(r) == "table" and r.result then
            println(pretty_or_raw(r.result))
        else
            println(pretty(r))
        end
    end },
    { key = "5", title = "oasis.chat append", desc = "Append history", args = {
        {name="id"},{name="role1"},{name="content1"},{name="role2"},{name="content2"}
    }, run = function(a)
        local r = ubus_append(a) or {}
        if type(r) == "table" and r.result then
            println(pretty_or_raw(r.result))
        else
            println(pretty(r))
        end
    end },
    { key = "6", title = "oasis.chat delete", desc = "Delete chat", args = { {name="id"} }, run = function(a)
        local r = ubus_delete(a) or {}
        println(pretty(r))
    end },
}

-- ============ CLI tests ============
local function exec_cli(cmd)
    local out = sys.exec(cmd .. " 2>/dev/null") or ""
    return out
end

local cli_menu = {
    { key = "1", title = "oasis list", desc = "List chats", args = {}, run = function()
        local out = exec_cli("oasis list")
        println(out)
    end },
    { key = "2", title = "oasis prompt <message>", desc = "Send single prompt", args = { {name="message"} }, run = function(a)
        local out = exec_cli("oasis prompt " .. (a.message or ""))
        println(out)
    end },
    { key = "3", title = "oasis chat no=<n>", desc = "Join chat (interactive wizard)", args = { {name="no"} }, run = function(a)
        local out = exec_cli("oasis chat no=" .. (a.no or ""))
        println(out)
    end },
    { key = "4", title = "oasis sysmsg list", desc = "List system messages", args = {}, run = function()
        local out = exec_cli("oasis sysmsg list")
        println(out)
    end },
    { key = "5", title = "oasis tools", desc = "List/execute tools", args = {}, run = function()
        local out = exec_cli("oasis tools")
        println(out)
    end },
}

-- ============ Local (Lua modules) tests ============
local function bool_str(v)
    return (v and "true" or "false")
end

local function write_temp_ini(path, section, key, value)
    local data = {}
    data[section or "default"] = {}
    data[section or "default"][key or "key"] = value or "value"
    local ok, err = common.update_conf_file(path, data)
    return ok ~= nil, err
end

local function read_file_or_err(path)
    local content, err = misc.read_file(path)
    if not content then
        return nil, err or "read error"
    end
    return content
end

local local_menu = {
    -- oasis.chat.misc
    { key = "1", title = "misc.normalize_path", desc = "Ensure trailing slash", args = { {name="path"} }, run = function(a)
        println(misc.normalize_path(a.path or ""))
    end },
    { key = "2", title = "misc.markdown", desc = "ANSI style convert (code/bold)", args = { {name="mark_mode"}, {name="message"} }, run = function(a)
        local mark = (a.mark_mode == "stateful") and {} or nil
        println(misc.markdown(mark, a.message or ""))
    end },
    { key = "3", title = "misc.touch", desc = "Create empty file if not exists (/tmp)", args = { {name="path"} }, run = function(a)
        local p = a.path or "/tmp/oasis_test.touch"
        local ok, err = misc.touch(p)
        println(string.format("ok=%s err=%s", bool_str(ok), tostring(err or "")))
    end },
    { key = "4", title = "misc.write_file/read_file", desc = "Write then read back (/tmp)", args = { {name="path"}, {name="data"} }, run = function(a)
        local p = a.path or "/tmp/oasis_test.txt"
        local ok, err = misc.write_file(p, a.data or "hello")
        println(string.format("write ok=%s err=%s", bool_str(ok), tostring(err or "")))
        local content, rerr = misc.read_file(p)
        println(string.format("read err=%s", tostring(rerr or "")))
        println(content or "")
    end },
    { key = "5", title = "misc.copy_file", desc = "Copy file (/tmp)", args = { {name="src"}, {name="dst"} }, run = function(a)
        local ok, err = misc.copy_file(a.src or "/tmp/oasis_test.txt", a.dst or "/tmp/oasis_test_copy.txt")
        println(string.format("ok=%s err=%s", bool_str(ok), tostring(err or "")))
    end },
    { key = "6", title = "misc.check_file_exist", desc = "Exists?", args = { {name="path"} }, run = function(a)
        println(bool_str(misc.check_file_exist(a.path or "/tmp/oasis_test.txt")))
    end },
    { key = "7", title = "misc.check_init_script_exists", desc = "Has /etc/init.d/<service>?", args = { {name="service"} }, run = function(a)
        println(bool_str(misc.check_init_script_exists(a.service or "network")))
    end },
    { key = "8", title = "misc.get_uptime", desc = "system uptime (seconds)", args = {}, run = function()
        println(tostring(misc.get_uptime() or ""))
    end },

    -- oasis.common
    { key = "9", title = "common.update_conf_file", desc = "Write INI to /tmp/test.ini", args = { {name="section"}, {name="key"}, {name="value"} }, run = function(a)
        local path = "/tmp/oasis_test.ini"
        local ok, err = write_temp_ini(path, a.section, a.key, a.value)
        println(string.format("ok=%s err=%s", bool_str(ok), tostring(err or "")))
        local data = common.load_conf_file(path)
        println(pretty(data))
    end },
    { key = "10", title = "common.load_conf_file", desc = "Read INI from path", args = { {name="path"} }, run = function(a)
        local data, err = common.load_conf_file(a.path or "/tmp/oasis_test.ini")
        if not data then println("error: " .. tostring(err)) return end
        println(pretty(data))
    end },
    { key = "11", title = "common.check_chat_format", desc = "Validate chat schema", args = { {name="chat_json"} }, run = function(a)
        local ok, chat = pcall(jsonc.parse, a.chat_json or "{}")
        if not ok then println("invalid json") return end
        println(bool_str(common.check_chat_format(chat)))
    end },
    { key = "12", title = "common.generate_service_id", desc = "Generate service id (urandom|seed)", args = { {name="method"} }, run = function(a)
        println(common.generate_service_id(a.method or "seed"))
    end },
    { key = "13", title = "common.check_server_loaded", desc = "ubus object loaded?", args = { {name="name"} }, run = function(a)
        println(bool_str(common.check_server_loaded(a.name or "oasis")))
    end },

    -- oasis.unified.chat.schema (ous)
    { key = "14", title = "ous.normalize_arguments", desc = "Normalize args (string/JSON/table)", args = { {name="args"} }, run = function(a)
        local normalized = ous.normalize_arguments(a.args or "{}")
        println(pretty(normalized))
    end },
    { key = "15", title = "ous.setup_msg (mock)", desc = "Append user msg using mock service", args = { {name="role"}, {name="message"}, {name="chat_json"} }, run = function(a)
        local mock_service = {
            get_config = function() return { id = "", sysmsg_key = "default" } end,
            get_format = function() return common.ai.format.chat end,
            handle_tool_result = function() return nil end,
            handle_tool_call = function() return nil end,
        }
        local chat = {}
        if a.chat_json and #a.chat_json > 0 then
            local ok, parsed = pcall(jsonc.parse, a.chat_json)
            chat = ok and parsed or {}
        end
        chat.messages = chat.messages or {}
        local speaker = { role = a.role or common.role.user, message = a.message or "" }
        local res = ous.setup_msg(mock_service, chat, speaker)
        println("result=" .. tostring(res))
        println(pretty(chat))
    end },
}

local function read_line(prompt)
    io.write(prompt or "> ")
    return io.read()
end

local function read_args(arg_defs)
    local args = {}
    for _, def in ipairs(arg_defs or {}) do
        args[def.name] = read_line(def.name .. ": ") or ""
    end
    return args
end

local function run_menu(menu)
    while true do
        println("")
        println("[function list]")
        for _, item in ipairs(menu) do
            println("[" .. item.key .. "] " .. item.title .. " - " .. item.desc)
        end
        println("[b] back  [q] quit")
        local sel = read_line("select: ")
        if sel == "q" then os.exit(0) end
        if sel == "b" then return end
        local chosen = nil
        for _, item in ipairs(menu) do if item.key == sel then chosen = item break end end
        if chosen then
            local a = read_args(chosen.args)
            println("\n[Result]----------------------------------------------")
            local ok, err = pcall(function() chosen.run(a) end)
            if not ok then println("Error: " .. tostring(err)) end
            println("------------------------------------------------------\n")
        end
    end
end

-- ============ entry ============
while true do
    println("")
    println("[route]")
    println("[1] ubus (oasis.chat)")
    println("[2] CLI  (/usr/bin/oasis)")
    println("[3] Local (Lua modules)")
    println("[q] quit")
    -- Optional: environment readiness hint (non-blocking)
    local ok_prepare = true
    local ok, res = pcall(function()
        return require("oasis.common").check_prepare_oasis()
    end)
    if ok and (res == false) then
        println("(note) oasis services may not be fully ready: ubus servers missing")
    end
    local r = read_line("select route: ")
    if r == "q" then break end
    if r == "1" then run_menu(ubus_menu) end
    if r == "2" then run_menu(cli_menu) end
    if r == "3" then run_menu(local_menu) end
end

println("terminate")