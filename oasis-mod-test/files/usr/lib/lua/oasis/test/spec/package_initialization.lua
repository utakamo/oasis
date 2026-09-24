local M = {}

local INITIALIZATION_MARKER =
    "/etc/oasis/.oasis-mod-tool-initialized-1.1.1-r11"
local OWNED_MANIFESTS = {
    "/etc/oasis/tool-manifest.d/lua.oasis.network.json",
    "/etc/oasis/tool-manifest.d/lua.oasis.service.json",
    "/etc/oasis/tool-manifest.d/lua.oasis.system.json",
    "/etc/oasis/tool-manifest.d/lua.oasis.tool.manager.json",
    "/etc/oasis/tool-manifest.d/lua.oasis.wireless.json",
    "/etc/oasis/tool-manifest.d/ucode.oasis_plugin_server.uc.json",
}

local function setup_script_path()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    local repository = source:match(
        "^(.*)/oasis%-mod%-test/files/usr/lib/lua/oasis/test/spec/"
            .. "package_initialization%.lua$")
    if repository then
        return repository
            .. "/oasis-mod-tool/files/usr/bin/oasis_tool_setup"
    end
    return "/usr/bin/oasis_tool_setup"
end

local function init_script_path()
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    local repository = source:match(
        "^(.*)/oasis%-mod%-test/files/usr/lib/lua/oasis/test/spec/"
            .. "package_initialization%.lua$")
    if repository then
        return repository
            .. "/oasis-mod-tool/files/etc/init.d/olt_tool.init"
    end
    return "/etc/init.d/olt_tool"
end

local function copy_prefix(values, length)
    local result = {}
    for index = 1, math.min(length, #values) do
        result[index] = values[index]
    end
    return result
end

local function run_initialize(options)
    options = options or {}
    local env = {
        marker_exists = options.marker_exists == true,
        enable_calls = 0,
        apply_calls = {},
        apply_options = {},
        touch_calls = {},
        delete_set_calls = {},
        delete_all_calls = 0,
        remove_calls = {},
        events = {},
        stderr = "",
    }
    local manifest_set = {}
    for _, path in ipairs(OWNED_MANIFESTS) do
        manifest_set[path] = true
    end

    local module_names = {
        "luci.model.uci",
        "oasis.common",
        "oasis.chat.misc",
        "oasis.local.tool.client",
        "oasis.local.tool.uci_transaction",
    }
    local saved_modules = {}
    for _, name in ipairs(module_names) do
        saved_modules[name] = package.loaded[name]
    end
    local saved_arg = arg
    local saved_exit = os.exit
    local saved_remove = os.remove
    local saved_stderr = io.stderr
    local exit_state = {}

    local delete_cursor = {}
    function delete_cursor:set(config, section, option, value)
        env.delete_set_calls[#env.delete_set_calls + 1] = {
            config = config,
            section = section,
            option = option,
            value = value,
        }
        return true
    end
    function delete_cursor:foreach(_, _, callback)
        if options.has_tools then
            callback({ [".name"] = "fixture" })
            return true
        end
        return false, nil
    end
    function delete_cursor:delete_all()
        env.delete_all_calls = env.delete_all_calls + 1
        return true
    end

    package.loaded["luci.model.uci"] = {
        cursor = function()
            return delete_cursor
        end,
    }
    package.loaded["oasis.common"] = {
        db = {
            uci = {
                cfg = "oasis",
                sect = { support = "support", tool = "tool" },
            },
        },
    }
    package.loaded["oasis.chat.misc"] = {
        check_file_exist = function(path)
            if path == INITIALIZATION_MARKER then
                return env.marker_exists
            end
            return manifest_set[path] == true
                and path ~= options.missing_manifest
        end,
        touch = function(path)
            env.events[#env.events + 1] = "touch:" .. tostring(path)
            env.touch_calls[#env.touch_calls + 1] = path
            if options.touch_fails then
                return false, "injected marker failure"
            end
            if path == INITIALIZATION_MARKER then
                env.marker_exists = true
            end
            return true
        end,
    }
    package.loaded["oasis.local.tool.client"] = {
        enable_remote_mcp_support = function()
            env.enable_calls = env.enable_calls + 1
            env.events[#env.events + 1] = "enable-remote-mcp"
            if options.enable_fails then
                return false, "injected remote MCP failure"
            end
            return true, { changed = true }
        end,
        apply_manifest_file = function(path, apply_options)
            env.apply_calls[#env.apply_calls + 1] = path
            env.apply_options[#env.apply_options + 1] = apply_options or {}
            env.events[#env.events + 1] = "apply:" .. tostring(path)
            if #env.apply_calls == options.fail_apply_index then
                return false, "injected manifest failure"
            end
            return true, { manifest_path = path }
        end,
    }
    package.loaded["oasis.local.tool.uci_transaction"] = {
        run = function(_, callback)
            if options.transaction_fails then
                return false, "injected transaction failure",
                    "uci_pending_changes"
            end
            local ok, value, code = callback(delete_cursor)
            if not ok then
                return false, value, code
            end
            return true, value
        end,
    }

    arg = { options.command or "initialize-package" }
    if options.force then
        arg[2] = "--force"
    elseif options.remove_marker then
        arg[2] = "--remove-marker"
    end
    io.stderr = {
        write = function(_, value)
            env.stderr = env.stderr .. tostring(value or "")
            return true
        end,
    }
    os.exit = function(code)
        exit_state.code = code
        error(exit_state, 0)
    end
    os.remove = function(path)
        env.remove_calls[#env.remove_calls + 1] = path
        if options.remove_fails then
            return nil, "injected remove failure"
        end
        if path == INITIALIZATION_MARKER then
            env.marker_exists = false
        end
        return true
    end

    local completed, execution_error = pcall(dofile, setup_script_path())

    os.exit = saved_exit
    os.remove = saved_remove
    io.stderr = saved_stderr
    arg = saved_arg
    for _, name in ipairs(module_names) do
        package.loaded[name] = saved_modules[name]
    end

    return {
        ok = completed,
        exit_code = exit_state.code,
        unexpected_error = (not completed and execution_error ~= exit_state)
            and execution_error or nil,
        env = env,
    }
end

function M.register(harness)
    harness:test("unit", "package init waits for rpcd before first-boot setup", function(t)
        local file, open_err = io.open(init_script_path(), "r")
        t:assert_not_nil(file, tostring(open_err))
        if not file then
            return
        end
        local source = file:read("*a")
        file:close()
        t:assert_contains(source, "START=20")
        t:assert_contains(source, "ubus -t 10 wait_for session")
        t:assert_contains(source, "lua /usr/bin/oasis_tool_setup init")
    end)

    harness:test("unit", "package initialization marker skips completed migration", function(t)
        local result = run_initialize({ marker_exists = true })
        t:assert_true(result.ok, tostring(result.unexpected_error))
        t:assert_nil(result.exit_code)
        t:assert_equal(0, result.env.enable_calls)
        t:assert_equal(0, #result.env.apply_calls)
        t:assert_equal(0, #result.env.touch_calls)
        t:assert_true(result.env.marker_exists)
        t:assert_equal(0, #result.env.events)
    end)

    harness:test("unit", "forced package initialization ignores an existing marker", function(t)
        local result = run_initialize({
            marker_exists = true,
            force = true,
        })
        t:assert_true(result.ok, tostring(result.unexpected_error))
        t:assert_nil(result.exit_code)
        t:assert_equal(1, result.env.enable_calls)
        t:assert_deep_equal(OWNED_MANIFESTS, result.env.apply_calls)
        t:assert_deep_equal({ INITIALIZATION_MARKER },
            result.env.touch_calls)
        t:assert_true(result.env.marker_exists)
        t:assert_equal("enable-remote-mcp", result.env.events[1])
        t:assert_equal("touch:" .. INITIALIZATION_MARKER,
            result.env.events[#result.env.events])
    end)

    harness:test("unit", "restored package schemas refresh without changing support flags or markers", function(t)
        for _, marker_exists in ipairs({ true, false }) do
            local result = run_initialize({
                command = "refresh-package-manifests",
                marker_exists = marker_exists,
            })
            t:assert_true(result.ok, tostring(result.unexpected_error))
            t:assert_nil(result.exit_code)
            t:assert_equal(0, result.env.enable_calls)
            t:assert_deep_equal(OWNED_MANIFESTS, result.env.apply_calls)
            for _, options in ipairs(result.env.apply_options) do
                t:assert_true(options.preserve_local_tool_support)
            end
            t:assert_equal(0, #result.env.touch_calls)
            t:assert_equal(marker_exists, result.env.marker_exists)
        end
    end)

    harness:test("unit", "restored schema refresh reports failures despite an existing marker", function(t)
        local result = run_initialize({
            command = "refresh-package-manifests",
            marker_exists = true,
            fail_apply_index = 3,
        })
        t:assert_false(result.ok)
        t:assert_nil(result.unexpected_error)
        t:assert_equal(1, result.exit_code)
        t:assert_equal(0, result.env.enable_calls)
        t:assert_deep_equal(copy_prefix(OWNED_MANIFESTS, 3), result.env.apply_calls)
        t:assert_equal(0, #result.env.touch_calls)
        t:assert_contains(result.env.stderr, "Failed to apply manifest")
    end)

    harness:test("unit", "package marker is created after every owned manifest succeeds", function(t)
        local result = run_initialize()
        t:assert_true(result.ok, tostring(result.unexpected_error))
        t:assert_nil(result.exit_code)
        t:assert_equal(1, result.env.enable_calls)
        t:assert_deep_equal(OWNED_MANIFESTS, result.env.apply_calls)
        t:assert_deep_equal({ INITIALIZATION_MARKER },
            result.env.touch_calls)
        t:assert_true(result.env.marker_exists)
        t:assert_equal("enable-remote-mcp", result.env.events[1])
        for index, path in ipairs(OWNED_MANIFESTS) do
            t:assert_equal("apply:" .. path,
                result.env.events[index + 1])
        end
        t:assert_equal("touch:" .. INITIALIZATION_MARKER,
            result.env.events[#result.env.events])
    end)

    harness:test("unit", "partial manifest failure leaves package migration unmarked", function(t)
        local failure_index = 3
        local result = run_initialize({
            fail_apply_index = failure_index,
        })
        t:assert_false(result.ok)
        t:assert_nil(result.unexpected_error)
        t:assert_equal(1, result.exit_code)
        t:assert_equal(1, result.env.enable_calls)
        t:assert_deep_equal(
            copy_prefix(OWNED_MANIFESTS, failure_index),
            result.env.apply_calls)
        t:assert_equal(0, #result.env.touch_calls)
        t:assert_false(result.env.marker_exists)
        t:assert_contains(result.env.stderr,
            "Failed to apply manifest " .. OWNED_MANIFESTS[failure_index])
        t:assert_equal(failure_index + 1, #result.env.events,
            "no later manifest or marker operation may run")
    end)

    harness:test("unit", "empty package tool state is removed idempotently", function(t)
        local result = run_initialize({
            command = "delete",
            remove_marker = true,
            marker_exists = true,
            has_tools = false,
        })
        t:assert_true(result.ok, tostring(result.unexpected_error))
        t:assert_nil(result.exit_code)
        t:assert_equal(2, #result.env.delete_set_calls)
        t:assert_equal("local_tool",
            result.env.delete_set_calls[1].option)
        t:assert_equal("remote_mcp_server",
            result.env.delete_set_calls[2].option)
        t:assert_equal(0, result.env.delete_all_calls,
            "delete-by-type must be skipped when no section exists")
        t:assert_deep_equal({ INITIALIZATION_MARKER },
            result.env.remove_calls)
        t:assert_false(result.env.marker_exists)
    end)
end

return M
