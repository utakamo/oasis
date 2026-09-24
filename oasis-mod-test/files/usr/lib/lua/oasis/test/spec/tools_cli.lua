local M = {}
local MODE_ON_OUTPUT = "Auto mode: \27[32mON\27[0m (managed by AI)\n\n"
local MODE_OFF_OUTPUT = "Auto mode: \27[33mOFF\27[0m (manual settings)\n\n"

local function replace(t, name, value)
    local old = package.loaded[name]
    package.loaded[name] = value
    t:on_cleanup(function() package.loaded[name] = old end)
end

local function entry_path()
    local source = debug.getinfo(1, "S").source or ""
    local repository = source:match(
        "^@(.*)/oasis%-mod%-test/files/usr/lib/lua/oasis/test/spec/tools_cli%.lua$")
    return repository and (repository .. "/oasis/files/usr/bin/oasis") or "/usr/bin/oasis"
end

-- Execute the real CLI entry point and chat.tools handler with all platform
-- services replaced. No UCI, UBUS, network, runtime files or reboot operations.
local function fixture(t)
    local env = { auto = false, local_tools = true, sets = {}, gets = 0,
        snapshots = 0, manual_sets = 0, preflights = 0 }
    local cursor = { get_bool = function() return env.local_tools end }
    env.cursor = cursor
    local common = {
        db = { uci = { cfg = "oasis", sect = { support = "support" } } },
        flag = { unload = {} }, endpoint = { type = { custom = "custom" } },
        ai = { service = {} },
        check_unloaded_plugin = function()
            env.preflights = env.preflights + 1
            return false
        end,
        check_prepare_oasis = function() return true end,
    }
    for _, name in ipairs({ "ollama", "openai", "anthropic", "gemini", "openrouter", "lmstudio" }) do
        common.ai.service[name] = { name = name }
    end
    replace(t, "oasis.common", common)
    replace(t, "luci.model.uci", { cursor = function() return cursor end })
    for _, name in ipairs({ "nixio.fs", "luci.util", "luci.jsonc", "oasis.chat.misc",
        "oasis.chat.datactrl", "oasis.unified.chat.schema", "oasis.chat.debug",
        "oasis.chat.error", "oasis.chat.tool_sequence" }) do
        replace(t, name, {})
    end
    replace(t, "oasis.chat.main", nil)
    env.state = {
        get_mode = function(actual_cursor)
            t:assert_equal(cursor, actual_cursor)
            env.gets = env.gets + 1
            if env.read_error then return nil, { error = env.read_error } end
            return { auto_mode = env.auto }
        end,
        set_auto_mode = function(actual_cursor, desired)
            t:assert_equal(cursor, actual_cursor)
            env.sets[#env.sets + 1] = desired
            if env.save_error then return { status = "NG", error = env.save_error } end
            env.auto = desired == "1"
            return { status = "OK", auto_mode = env.auto }
        end,
        snapshot = function()
            env.snapshots = env.snapshots + 1
            return { auto_mode = env.auto, tools = {
                { server = "fixture", name = "scan", enable = "0" },
                { server = "oasis.tool.manager", name = "get_tool_list", enable = "1" },
            } }
        end,
        is_control_tool = function(server) return server == "oasis.tool.manager" end,
        set_enabled_persistent = function(_, server, name, desired, options)
            env.manual_sets = env.manual_sets + 1
            t:assert_equal("fixture", server)
            t:assert_equal("scan", name)
            t:assert_true(desired)
            t:assert_true(options.manual_only)
            return { status = "OK" }
        end,
    }
    replace(t, "oasis.local.tool.state", env.state)

    local saved_print, saved_arg, saved_exit = print, arg, os.exit
    local saved_read, saved_write, saved_flush, saved_stderr = io.read, io.write, io.flush, io.stderr
    t:on_cleanup(function()
        _G.print, _G.arg, os.exit = saved_print, saved_arg, saved_exit
        io.read, io.write, io.flush, io.stderr = saved_read, saved_write, saved_flush, saved_stderr
    end)
    _G.print = function(value) env.stdout = env.stdout .. tostring(value or "") .. "\n" end
    io.write = function(value) env.stdout = env.stdout .. value end
    io.flush = function() end
    io.read = function()
        env.reads = env.reads + 1
        if not env.inputs then error("Unexpected interactive prompt") end
        return env.inputs[env.reads]
    end
    io.stderr = { write = function(_, value) env.stderr = env.stderr .. value end }
    replace(t, "oasis.console", { print = _G.print })
    local exit_marker = {}
    os.exit = function(code)
        env.exit_code = code
        error(exit_marker, 0)
    end
    local entry = assert(loadfile(entry_path()))
    function env.run(argv)
        env.stdout, env.stderr, env.exit_code, env.reads = "", "", nil, 0
        _G.arg = argv
        local ok, err = pcall(entry)
        if not ok and err ~= exit_marker then error(err, 0) end
        return env.exit_code or 0
    end
    return env
end

local function use_shared_state(t, env)
    env.support, env.sections, env.commits = {}, {}, 0
    for _, name in ipairs({ "get_tool_list", "set_tool_enabled", "set_tool_disabled" }) do
        env.sections[#env.sections + 1] = {
            server = "oasis.tool.manager", name = name, enable = "0",
        }
    end
    env.sections[4] = { server = "fixture", name = "scan", enable = "1" }
    function env.cursor:get_all() return env.support end
    function env.cursor:foreach(_, _, callback)
        for _, section in ipairs(env.sections) do callback(section) end
        return true
    end
    function env.cursor:set(_, section, option, value)
        t:assert_equal("support", section, "manual tool settings must remain unchanged")
        env.support[option] = value
        return true
    end
    replace(t, "oasis.local.tool.auto_store", {
        with_lock = function(callback)
            if env.lock_busy then return nil, "Auto lock busy." end
            return callback()
        end,
        read = function() error("Mode commands must not read volatile tool selection") end,
        write = function() error("Mode commands must not overwrite volatile tool selection") end,
    })
    replace(t, "oasis.local.tool.uci_transaction", {
        run = function(options, callback)
            t:assert_equal(env.cursor, options.cursor)
            local before = {}
            for key, value in pairs(env.support) do before[key] = value end
            local ok, result, code = callback(env.cursor)
            if not ok or env.commit_fails then
                env.support = before
                if env.commit_fails then return false, "commit failed", "uci_commit_failed" end
                return false, result, code
            end
            if result.changed then env.commits = env.commits + 1 end
            return true, result
        end,
    })
    replace(t, "oasis.local.tool.state", nil)
    env.state = require("oasis.local.tool.state")
end

function M.register(harness)
    harness:test("portable", "tools CLI on and off use the shared Auto mode API without prompts", function(t)
        local env = fixture(t)
        for _, command in ipairs({ "on", "off" }) do
            t:assert_equal(0, env.run({ "tools", command }))
            t:assert_equal(command == "on" and MODE_ON_OUTPUT or MODE_OFF_OUTPUT, env.stdout)
            t:assert_equal("", env.stderr)
            t:assert_equal(0, env.reads)
        end
        t:assert_deep_equal({ "1", "0" }, env.sets)
        t:assert_equal(0, env.manual_sets)
        t:assert_equal(0, env.preflights, "mode commands must not offer reboot/service restart")
    end)

    harness:test("portable", "tools CLI status reports both modes without writes or runtime reads", function(t)
        local env = fixture(t)
        for _, auto in ipairs({ false, true }) do
            env.auto = auto
            t:assert_equal(0, env.run({ "tools", "status" }))
            t:assert_equal(auto and MODE_ON_OUTPUT or MODE_OFF_OUTPUT, env.stdout)
            t:assert_equal(0, env.reads)
        end
        t:assert_equal(2, env.gets)
        t:assert_equal(0, #env.sets)
        t:assert_equal(0, env.snapshots)
        t:assert_equal(0, env.manual_sets)
        t:assert_equal(0, env.preflights)
    end)

    harness:test("portable", "tools CLI rejects unknown commands and extra arguments before changing state", function(t)
        local env = fixture(t)
        for _, argv in ipairs({ { "tools", "auto", "on" }, { "tools", "ON" },
            { "tools", "" }, { "tools", "enable" }, { "tools", "on", "off" },
            { "tools", "off", "extra" }, { "tools", "status", "extra" } }) do
            t:assert_equal(2, env.run(argv))
            t:assert_contains(env.stderr, "Usage: oasis tools [on|off|status]")
            t:assert_equal("", env.stdout)
            t:assert_equal(0, env.reads)
        end
        t:assert_equal(0, #env.sets)
        t:assert_equal(0, env.gets)
        t:assert_equal(0, env.snapshots)
    end)

    harness:test("portable", "tools CLI reports read and save failures with a nonzero exit", function(t)
        local env = fixture(t)
        env.read_error = "Invalid Auto mode configuration."
        t:assert_equal(1, env.run({ "tools", "status" }))
        t:assert_contains(env.stderr, env.read_error)
        t:assert_equal("", env.stdout)
        for _, message in ipairs({ "commit failed", "Auto lock busy.",
            "Refresh tools before enabling Auto mode." }) do
            env.save_error = message
            t:assert_equal(1, env.run({ "tools", "on" }))
            t:assert_contains(env.stderr, message)
            t:assert_equal("", env.stdout)
            t:assert_false(env.auto)
        end
        env.auto, env.save_error = true, "commit failed"
        t:assert_equal(1, env.run({ "tools", "off" }))
        t:assert_contains(env.stderr, "commit failed")
        t:assert_true(env.auto)
    end)

    harness:test("portable", "tools CLI reports unavailable local-tool support without writing", function(t)
        local env = fixture(t)
        env.local_tools = false
        for _, command in ipairs({ "on", "off", "status" }) do
            t:assert_equal(1, env.run({ "tools", command }))
            t:assert_contains(env.stderr, "oasis-mod-tool")
            t:assert_equal("", env.stdout)
        end
        env.local_tools = true
        replace(t, "oasis.local.tool.state", {})
        t:assert_equal(1, env.run({ "tools", "on" }))
        t:assert_contains(env.stderr, "Install or update oasis-mod-tool")
        t:assert_equal(0, #env.sets)
    end)

    harness:test("portable", "tools CLI without a subcommand preserves manual edits and Auto read-only listing", function(t)
        local env = fixture(t)
        env.inputs = { "E", "1" }
        t:assert_equal(0, env.run({ "tools" }))
        t:assert_equal(1, env.manual_sets)
        t:assert_equal(2, env.reads)
        t:assert_contains(env.stdout, MODE_OFF_OUTPUT .. "- fixture\n")
        t:assert_contains(env.stdout, "Enabled tool: scan")
        env.auto, env.inputs = true, nil
        t:assert_equal(0, env.run({ "tools" }))
        t:assert_equal(0, env.reads)
        t:assert_equal(1, env.manual_sets)
        t:assert_contains(env.stdout, MODE_ON_OUTPUT .. "- fixture\n")
        t:assert_contains(env.stdout, "oasis tools off")
        t:assert_false(env.stdout:find("get_tool_list", 1, true) ~= nil)
        t:assert_equal(0, #env.sets)
    end)

    harness:test("portable", "tools CLI help describes Auto subcommands", function(t)
        local env = fixture(t)
        t:assert_equal(0, env.run({}))
        t:assert_contains(env.stdout, "tools on|off|status")
        t:assert_contains(env.stdout, "shared Auto mode")
    end)

    harness:test("portable", "tools CLI shared state updates the mode and generation without resetting selection", function(t)
        local env = fixture(t)
        use_shared_state(t, env)
        t:assert_equal(0, env.run({ "tools", "status" }))
        t:assert_equal(MODE_OFF_OUTPUT, env.stdout)
        t:assert_nil(next(env.support), "status must not initialize absent UCI options")
        for index, command in ipairs({ "on", "off", "on" }) do
            t:assert_equal(0, env.run({ "tools", command }))
            t:assert_equal(command == "on" and "1" or "0", env.support.tool_auto)
            t:assert_equal(tostring(index), env.support.tool_auto_generation)
            t:assert_equal(index, env.commits)
            -- Repeating a command is successful but must not increment generation.
            t:assert_equal(0, env.run({ "tools", command }))
            t:assert_equal(tostring(index), env.support.tool_auto_generation)
            t:assert_equal(index, env.commits)
            t:assert_equal("1", env.sections[4].enable)
            t:assert_equal(0, env.run({ "tools", "status" }))
            t:assert_equal(command == "on" and MODE_ON_OUTPUT or MODE_OFF_OUTPUT, env.stdout)
            t:assert_equal(index, env.commits)
        end
    end)

    harness:test("portable", "tools CLI shared state preserves mode on commit lock and manager failures", function(t)
        local env = fixture(t)
        use_shared_state(t, env)
        env.commit_fails = true
        t:assert_equal(1, env.run({ "tools", "on" }))
        t:assert_contains(env.stderr, "commit failed")
        t:assert_nil(next(env.support))
        env.commit_fails, env.lock_busy = false, true
        t:assert_equal(1, env.run({ "tools", "on" }))
        t:assert_contains(env.stderr, "Auto lock busy")
        env.lock_busy = false
        env.sections[1].conflict = "1"
        t:assert_equal(1, env.run({ "tools", "on" }))
        t:assert_contains(env.stderr, "Refresh tools before enabling Auto mode")
        t:assert_nil(next(env.support))
        t:assert_equal(0, env.commits)
        env.support.tool_auto = "invalid"
        t:assert_equal(1, env.run({ "tools", "status" }))
        t:assert_contains(env.stderr, "Invalid Auto mode configuration")
    end)
end

return M
