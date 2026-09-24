local jsonc = require("luci.jsonc")
local state = require("oasis.local.tool.state")
local M = {}

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end

local function replace(t, name, value)
    local old = package.loaded[name]
    package.loaded[name] = value
    t:on_cleanup(function() package.loaded[name] = old end)
end

local function fixture(t)
    local env = { support = {}, sections = {}, writes = 0, commits = 0,
        runtime = { version = 1, enabled = {} } }
    for _, name in ipairs({ "get_tool_list", "set_tool_enabled", "set_tool_disabled" }) do
        env.sections[#env.sections + 1] = { [".name"] = name,
            [".type"] = "tool", server = "oasis.tool.manager", name = name,
            type = "function", enable = "1", conflict = "0" }
    end
    for index, name in ipairs({ "weather", "scan" }) do
        env.sections[#env.sections + 1] = { [".name"] = "tool" .. index,
            [".type"] = "tool", server = "fixture.tools", name = name,
            type = "function", enable = index == 1 and "1" or "0",
            description = "fixture " .. name, conflict = "0" }
    end
    local cursor = {}
    function cursor:get_all() return copy(env.support) end
    function cursor:foreach(_, _, callback)
        for _, section in ipairs(env.sections) do callback(copy(section)) end
        return true
    end
    function cursor:set(_, section, option, value)
        env.writes = env.writes + 1
        if env.set_fails then return false end
        if section == "support" then env.support[option] = value; return true end
        for _, entry in ipairs(env.sections) do
            if entry[".name"] == section then entry[option] = value; return true end
        end
        return false
    end
    env.cursor = cursor
    function cursor:get_bool() return true end
    replace(t, "oasis.local.tool.auto_store", {
        read = function()
            if env.corrupt then return nil, "Invalid Auto tool state." end
            return copy(env.runtime)
        end,
        write = function(value)
            if env.write_fails then return nil, "Auto write failed." end
            env.runtime = copy(value)
            return true
        end,
        with_lock = function(callback)
            if env.lock_busy then return nil, "Auto lock busy." end
            return callback()
        end,
    })
    replace(t, "oasis.local.tool.uci_transaction", {
        run = function(options, callback)
            t:assert_equal(cursor, options.cursor)
            local support, sections = copy(env.support), copy(env.sections)
            local ok, result, code = callback(cursor)
            if env.commit_fails or not ok then
                env.support, env.sections = support, sections
                if env.commit_fails then return false, "commit failed", "uci_commit_failed" end
                return false, result, code
            end
            if result.changed then env.commits = env.commits + 1 end
            return true, result
        end,
    })
    return env
end

local function enabled(t, env)
    local snapshot, err = state.snapshot(env.cursor)
    t:assert_not_nil(snapshot, err and err.error)
    local names = {}
    for _, tool in ipairs(snapshot.tools) do
        if tool.enabled then names[#names + 1] = tool.name end
    end
    table.sort(names)
    return table.concat(names, ",")
end

local CONTROLS = "get_tool_list,set_tool_disabled,set_tool_enabled"

local function store_fixture(t)
    local env = { files = {}, stats = {}, closes = 0, locks = 0 }
    local dir = "/tmp/oasis-tool-auto"
    env.path = dir .. "/state.json"
    local function stat(kind)
        return { type = kind, uid = 0, nlink = 1,
            modestr = kind == "dir" and "rwx------" or "rw-------" }
    end
    local fs = {
        lstat = function(path)
            if env.stats[path] then return copy(env.stats[path]) end
            return nil, 2
        end,
        mkdir = function(path, mode)
            t:assert_equal(dir, path)
            t:assert_equal("0700", mode)
            env.stats[path] = stat("dir")
            return true
        end,
        readfile = function(path, limit)
            local raw = env.files[path]
            return raw and raw:sub(1, limit)
        end,
        unlink = function(path)
            env.stats[path], env.files[path] = nil, nil
            return true
        end,
        rename = function(source, destination)
            if env.rename_fails then return false end
            env.files[destination] = env.files[source]
            env.stats[destination] = env.stats[source]
            env.files[source], env.stats[source] = nil, nil
            return true
        end,
    }
    local nixio = {
        open_flags = function(...) return table.concat({...}, ",") end,
        open = function(path, flags, mode)
            t:assert_equal("0600", mode)
            if flags ~= "a" then t:assert_equal("wronly,creat,excl", flags) end
            env.stats[path] = stat("reg")
            return {
                lock = function(_, command)
                    if command == "tlock" then
                        env.locks = env.locks + 1
                        return not env.busy
                    end
                    return true
                end,
                close = function() env.closes = env.closes + 1; return true end,
                writeall = function(_, raw)
                    if env.during_write then env.during_write() end
                    env.files[path] = raw
                    return env.short_write and 1 or #raw
                end,
            }
        end,
    }
    replace(t, "nixio.fs", fs)
    replace(t, "nixio", nixio)
    replace(t, "oasis.local.tool.auto_store", nil)
    env.store = require("oasis.local.tool.auto_store")
    env.stat = stat
    return env
end

function M.register(harness)
    harness:test("unit", "CLI tool management respects Auto mode and preserves manual configuration", function(t)
        local env = fixture(t)
        replace(t, "luci.model.uci", { cursor = function() return env.cursor end })
        replace(t, "nixio.fs", {})
        replace(t, "oasis.console", {})
        replace(t, "oasis.chat.main", nil)
        local main = require("oasis.chat.main")
        local original_print, original_read = print, io.read
        local original_write, original_flush = io.write, io.flush
        local output, inputs, reads = {}, { "E", "1" }, 0
        t:on_cleanup(function()
            _G.print, io.read = original_print, original_read
            io.write, io.flush = original_write, original_flush
        end)
        _G.print = function(value) output[#output + 1] = tostring(value or "") end
        io.write = function(value) output[#output + 1] = value end
        io.flush = function() end
        io.read = function() reads = reads + 1; return inputs[reads] end
        main.tools()
        t:assert_equal("1", env.sections[5].enable, "sorted first normal tool is scan")
        t:assert_equal(1, env.commits)
        t:assert_false(table.concat(output):find("get_tool_list", 1, true) ~= nil)
        state.set_auto_mode(env.cursor, "1")
        output, reads = {}, 0
        local before = env.writes
        main.tools()
        t:assert_equal(0, reads, "Auto mode must not prompt for manual changes")
        t:assert_equal(before, env.writes)
        t:assert_contains(table.concat(output), "Auto mode: \27[32mON\27[0m (managed by AI)")
        t:assert_contains(table.concat(output), "OFF on the Tools page")
        t:assert_equal("1", env.sections[5].enable)
    end)

    harness:test("unit", "Auto and Manual selections are isolated across OFF ON and reboot", function(t)
        local env = fixture(t)
        t:assert_equal("weather", enabled(t, env))
        t:assert_equal("OK", state.set_auto_mode(env.cursor, "1").status)
        t:assert_equal("1", env.support.tool_auto)
        t:assert_equal(CONTROLS, enabled(t, env))
        t:assert_equal("OK", state.set_auto_enabled(env.cursor, "fixture.tools", "scan", true).status)
        t:assert_equal("0", env.sections[5].enable)
        t:assert_equal(2, env.writes, "Auto selection must not write UCI")
        t:assert_equal("get_tool_list,scan,set_tool_disabled,set_tool_enabled", enabled(t, env))
        t:assert_equal("OK", state.set_auto_mode(env.cursor, "0").status)
        t:assert_equal("weather", enabled(t, env))
        t:assert_equal("OK", state.set_auto_mode(env.cursor, "1").status)
        t:assert_equal("get_tool_list,scan,set_tool_disabled,set_tool_enabled", enabled(t, env))
        t:assert_equal("3", env.support.tool_auto_generation)
        -- Reboot clears only /tmp; UCI survives. No real files or UCI touched.
        env.runtime = { version = 1, enabled = {} }
        t:assert_equal("1", env.support.tool_auto)
        t:assert_equal(CONTROLS, enabled(t, env))
        t:assert_equal("1", env.sections[4].enable)
        t:assert_equal("0", env.sections[5].enable)
    end)

    harness:test("unit", "Auto managers ignore legacy flags and protect controls and manual settings", function(t)
        local env = fixture(t)
        for index = 1, 3 do env.sections[index].enable = "0" end
        t:assert_equal("auto_mode_disabled", state.set_auto_enabled(env.cursor, "fixture.tools", "scan", true).code)
        t:assert_equal("OK", state.set_auto_mode(env.cursor, "1").status)
        t:assert_equal(CONTROLS, enabled(t, env))
        for _, name in ipairs({ "get_tool_list", "set_tool_enabled", "set_tool_disabled" }) do
            for _, desired in ipairs({ true, false }) do
                t:assert_equal("protected_control_tool",
                    state.set_auto_enabled(env.cursor, "oasis.tool.manager", name, desired).code)
            end
        end
        t:assert_equal("auto_mode_active", state.set_enabled_persistent(env.cursor,
            "fixture.tools", "scan", true, { manual_only = true }).code)
        t:assert_equal("0", env.sections[5].enable)
        state.set_auto_mode(env.cursor, "0")
        t:assert_equal("protected_control_tool", state.set_enabled_persistent(env.cursor,
            "oasis.tool.manager", "get_tool_list", true, { manual_only = true }).code)
        t:assert_equal("OK", state.set_enabled_persistent(env.cursor,
            "fixture.tools", "scan", true, { manual_only = true }).status)
        t:assert_equal("scan,weather", enabled(t, env))
    end)

    harness:test("unit", "Auto state is bound to exact tool identity and current definition", function(t)
        local env = fixture(t)
        state.set_auto_mode(env.cursor, "1")
        t:assert_equal("tool_not_found", state.set_auto_enabled(env.cursor, "wrong.server", "scan", true).code)
        state.set_auto_enabled(env.cursor, "fixture.tools", "scan", true)
        t:assert_false(state.set_auto_enabled(env.cursor, "fixture.tools", "scan", true).changed)
        env.sections[5][".name"] = "refreshed_section_id"
        t:assert_contains(enabled(t, env), "scan")
        env.sections[5].description = "changed definition"
        t:assert_equal(CONTROLS, enabled(t, env))
        t:assert_true(state.set_auto_enabled(env.cursor, "fixture.tools", "scan", true).changed)
        env.sections[5].conflict = "1"
        t:assert_equal(CONTROLS, enabled(t, env))
        t:assert_equal("tool_conflict", state.set_auto_enabled(env.cursor, "fixture.tools", "scan", true).code)
        env.sections[5].conflict = "0"
        local duplicate = copy(env.sections[5])
        duplicate.server = "other.server"
        env.sections[#env.sections + 1] = duplicate
        t:assert_equal(CONTROLS, enabled(t, env))
        t:assert_equal("tool_conflict", state.set_auto_enabled(env.cursor, "fixture.tools", "scan", true).code)
    end)

    harness:test("unit", "Auto mode fails closed on save errors without damaging either selection", function(t)
        local env = fixture(t)
        env.commit_fails = true
        t:assert_equal("uci_commit_failed", state.set_auto_mode(env.cursor, "1").code)
        t:assert_equal("weather", enabled(t, env))
        env.commit_fails = false
        env.set_fails = true
        t:assert_equal("uci_set_failed", state.set_auto_mode(env.cursor, "1").code)
        env.set_fails = false
        env.lock_busy = true
        t:assert_equal("auto_state_failed", state.set_auto_mode(env.cursor, "1").code)
        env.lock_busy = false
        t:assert_equal("invalid_enable", state.set_auto_mode(env.cursor, "yes").code)
        state.set_auto_mode(env.cursor, "1")
        env.write_fails = true
        t:assert_equal("auto_state_failed", state.set_auto_enabled(env.cursor, "fixture.tools", "scan", true).code)
        t:assert_equal(CONTROLS, enabled(t, env))
        env.corrupt = true
        local snapshot, err = state.snapshot(env.cursor)
        t:assert_nil(snapshot)
        t:assert_equal("auto_state_failed", err.code)
        -- Disabling Auto does not need to decode the damaged runtime file.
        t:assert_equal("OK", state.set_auto_mode(env.cursor, "0").status)
        t:assert_equal("weather", enabled(t, env))
    end)

    harness:test("unit", "Auto mode requires unique managers and rejects stale mode tokens", function(t)
        local env = fixture(t)
        local old_mode = state.get_mode(env.cursor)
        env.sections[1].conflict = "1"
        t:assert_equal("control_tools_unavailable", state.set_auto_mode(env.cursor, "1").code)
        env.sections[1].conflict = "0"
        state.set_auto_mode(env.cursor, "1")
        state.set_auto_mode(env.cursor, "0")
        local snapshot, err = state.snapshot(env.cursor, old_mode.token)
        t:assert_nil(snapshot)
        t:assert_equal("tool_mode_changed", err.code)
        local current = state.get_mode(env.cursor)
        t:assert_false(state.set_auto_mode(env.cursor, "0").changed)
        t:assert_equal(current.token, state.get_mode(env.cursor).token)
        env.support.tool_auto = "invalid"
        t:assert_nil(state.get_mode(env.cursor))
    end)

    harness:test("unit", "Auto store starts empty and atomically publishes private runtime files", function(t)
        local env = store_fixture(t)
        local store = env.store
        t:assert_equal(1, store.read().version)
        t:assert_nil(next(store.read().enabled))
        env.during_write = function()
            t:assert_nil(next(store.read().enabled), "unpublished file became visible")
        end
        local result = store.with_lock(function()
            return store.write({ version = 1, enabled = { fixture = "signature" } })
        end)
        t:assert_true(result)
        t:assert_equal("signature", store.read().enabled.fixture)
        t:assert_equal(2, env.closes)
        t:assert_nil(env.files[env.path .. ".new"])
    end)

    harness:test("unit", "Auto store rejects corrupt unsafe and interrupted writes", function(t)
        local env = store_fixture(t)
        local store = env.store
        store.with_lock(function() return store.write({ version = 1, enabled = { old = "kept" } }) end)
        env.rename_fails = true
        t:assert_nil(store.with_lock(function()
            return store.write({ version = 1, enabled = { new = "lost" } })
        end))
        t:assert_equal("kept", store.read().enabled.old)
        env.rename_fails, env.short_write = false, true
        t:assert_nil(store.with_lock(function() return store.write({ version = 1, enabled = {} }) end))
        t:assert_equal("kept", store.read().enabled.old)
        env.busy = true
        local called = false
        t:assert_nil(store.with_lock(function() called = true end))
        t:assert_false(called)
        env.busy = false
        for _, raw in ipairs({ "{", "{}", '{"version":2,"enabled":{}}', '{"version":1,"enabled":{"a":true}}' }) do
            env.files[env.path] = raw
            t:assert_nil(store.read())
        end
        env.files[env.path] = '{"version":1,"enabled":{}}'
        for _, field in ipairs({ "type", "uid", "modestr", "nlink" }) do
            local original = env.stats[env.path][field]
            env.stats[env.path][field] = "unsafe"
            t:assert_nil(store.read())
            env.stats[env.path][field] = original
        end
        env.stats[env.path .. ".new"] = env.stat("lnk")
        t:assert_nil(store.with_lock(function() return store.write({ version = 1, enabled = {} }) end))
        env.stats["/tmp/oasis-tool-auto"].type = "lnk"
        t:assert_nil(store.read())
    end)

    harness:test("unit", "tool schema and dispatch use the same effective Auto selection", function(t)
        local env = fixture(t)
        local calls = {}
        replace(t, "luci.model.uci", { cursor = function() return env.cursor end })
        replace(t, "oasis.local.tool.package.manager", {})
        replace(t, "oasis.chat.misc", { check_file_exist = function() return false end })
        replace(t, "luci.sys", {})
        replace(t, "nixio.fs", {})
        replace(t, "nixio", {})
        replace(t, "oasis.chat.debug", { log = function() end })
        replace(t, "oasis.local.tool.client", nil)
        local common = require("oasis.common")
        local original_call = common.ubus_call
        common.ubus_call = function(server, name)
            calls[#calls + 1] = server .. ":" .. name
            return { status = "OK" }
        end
        t:on_cleanup(function() common.ubus_call = original_call end)
        local client = require("oasis.local.tool.client")
        t:assert_equal("weather", client.get_function_call_schema()[1].name)
        state.set_auto_mode(env.cursor, "1")
        t:assert_equal(3, #client.get_function_call_schema())
        client.exec_server_tool("silent", "weather", {})
        t:assert_equal(0, #calls)
        state.set_auto_enabled(env.cursor, "fixture.tools", "scan", true)
        t:assert_equal(4, #client.get_function_call_schema())
        local mode = state.get_mode(env.cursor)
        client.exec_server_tool("silent", "scan", {}, mode.token)
        t:assert_equal("fixture.tools:scan", calls[1])
        state.set_auto_mode(env.cursor, "0")
        t:assert_equal("tool_mode_changed", client.exec_server_tool("silent", "weather", {}, mode.token).code)
        t:assert_equal(1, #calls)
        t:assert_equal("weather", client.get_function_call_schema()[1].name)
    end)
end

return M
