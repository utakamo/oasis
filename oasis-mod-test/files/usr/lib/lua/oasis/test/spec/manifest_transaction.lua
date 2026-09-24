local M = {}

local manifest_path = "/etc/oasis/tool-manifest.d/lua.fixture.server.json"
local source_path = "/usr/libexec/rpcd/fixture.server"

local function deep_copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[deep_copy(key, seen)] = deep_copy(item, seen)
    end
    return copy
end

local function fixture_manifest()
    return {
        version = 1,
        source_type = "lua_script",
        source_path = source_path,
        tools = {
            {
                server = "fixture.server",
                name = "fixture_tool",
                type = "function",
                description = "Fixture tool",
                execution_message = "",
                download_message = "",
                timeout = "",
                required = { "value" },
                properties = {
                    {
                        name = "value",
                        type = "string",
                        description = "Fixture value",
                    },
                },
                additional_properties = false,
            },
        },
    }
end

local function fixture_sections()
    return {
        {
            [".name"] = "owned",
            name = "fixture_tool",
            script = "lua",
            server = "fixture.server",
            enable = "1",
            type = "function",
            description = "Fixture tool",
            execution_message = "",
            download_message = "",
            timeout = "",
            conflict = "0",
            required = { "value" },
            property = { "value:string:Fixture value" },
            additionalProperties = "0",
            source_type = "lua_script",
            source_path = source_path,
            manifest_path = manifest_path,
        },
        {
            [".name"] = "custom",
            name = "custom_tool",
            script = "lua",
            server = "custom.server",
            enable = "1",
            type = "function",
            description = "Custom tool",
            conflict = "0",
            additionalProperties = "0",
        },
    }
end

local function new_fixture(options)
    options = options or {}
    local env = {
        base_sections = deep_copy(options.base_sections
            or fixture_sections()),
        base_support = options.base_support or "1",
        base_remote_support = "0",
        shared_changes = {},
        session_views = {},
        session_support = {},
        session_remote_support = {},
        session_changes = {},
        created_sessions = {},
        destroyed_sessions = {},
        commit_sessions = {},
        mutation_calls = 0,
        delete_all_calls = 0,
        selected_session = options.original_session_id,
        original_session_id = options.original_session_id,
        next_session = 0,
        next_section = 0,
        lock_released = false,
        revert_calls = 0,
        session_calls = {},
        access_calls = {},
        logs = {},
    }

    local function private_session_selected()
        return env.selected_session ~= nil
            and env.session_views[env.selected_session] ~= nil
    end

    local function current_key()
        if private_session_selected() then
            return env.selected_session
        end
        return "shared"
    end

    local function current_sections()
        if private_session_selected() then
            return env.session_views[env.selected_session]
        end
        return env.base_sections
    end

    local function current_support()
        if private_session_selected() then
            return env.session_support[env.selected_session]
        end
        return env.base_support
    end

    local function current_remote_support()
        if private_session_selected() then
            return env.session_remote_support[env.selected_session]
        end
        return env.base_remote_support
    end

    local function mark_change(kind)
        local key = current_key()
        local changes
        if key == "shared" then
            changes = env.shared_changes
        else
            changes = env.session_changes[key]
        end
        changes[#changes + 1] = { kind }
    end

    local function should_fail(method)
        if env.fail_method == method and not env.failure_consumed then
            env.failure_consumed = true
            return true
        end
        return false
    end

    local cursor = {}

    function cursor:get_session_id()
        return env.selected_session
    end

    function cursor:set_session_id(session_id)
        if env.raise_restore and private_session_selected()
            and session_id ~= env.selected_session then
            error("injected restore failure")
        end
        if env.fail_select and env.session_views[session_id] then
            return false, "injected select failure"
        end
        env.selected_session = session_id
        if env.session_views[session_id] and env.inject_shared_on_switch
            and not env.shared_change_injected then
            env.shared_change_injected = true
            env.shared_changes[#env.shared_changes + 1] = {
                "set", "unrelated", "option", "pending",
            }
        end
        return true
    end

    function cursor:changes()
        if private_session_selected() then
            return env.session_changes[env.selected_session]
        end
        return env.shared_changes
    end

    function cursor:foreach(_, section_type, callback)
        if section_type ~= "tool" then
            return false, nil
        end
        if env.raise_private_foreach and private_session_selected() then
            error("injected private foreach failure")
        end
        local sections = current_sections()
        local visited = false
        for _, section in ipairs(sections) do
            visited = true
            if callback(deep_copy(section)) == false then
                break
            end
        end
        return visited, nil
    end

    function cursor:get(_, section, option)
        if section == "support" and option == "local_tool" then
            return current_support(), nil
        elseif section == "support" and option == "remote_mcp_server" then
            return current_remote_support(), nil
        end
        return nil, nil
    end

    function cursor:delete(_, section_name)
        env.mutation_calls = env.mutation_calls + 1
        if should_fail("delete") then
            return false, "injected delete failure"
        end
        local sections = current_sections()
        for index, section in ipairs(sections) do
            if section[".name"] == section_name then
                table.remove(sections, index)
                mark_change("delete")
                return true, nil
            end
        end
        return false, "section not found"
    end

    function cursor:delete_all(_, section_type)
        env.mutation_calls = env.mutation_calls + 1
        env.delete_all_calls = env.delete_all_calls + 1
        if section_type ~= "tool" then
            return false, "unexpected section type"
        end
        if should_fail("delete_all") then
            return false, "injected delete_all failure"
        end
        local sections = current_sections()
        if #sections == 0 then
            return false, "Entry not found"
        end
        for index = #sections, 1, -1 do
            table.remove(sections, index)
        end
        mark_change("delete_all")
        return true, nil
    end

    function cursor:section(_, section_type)
        env.mutation_calls = env.mutation_calls + 1
        if should_fail("section") then
            return false, "injected section failure"
        end
        env.next_section = env.next_section + 1
        local section_name = "cfg" .. tostring(env.next_section)
        current_sections()[#current_sections() + 1] = {
            [".name"] = section_name,
            [".type"] = section_type,
        }
        mark_change("section")
        return section_name, nil
    end

    local function find_section(section_name)
        for _, section in ipairs(current_sections()) do
            if section[".name"] == section_name then
                return section
            end
        end
        return nil
    end

    function cursor:set(_, section_name, option, value)
        env.mutation_calls = env.mutation_calls + 1
        if should_fail("set") then
            return false, "injected set failure"
        end
        if section_name == "support" and option == "local_tool" then
            if private_session_selected() then
                env.session_support[env.selected_session] = value
            else
                env.base_support = value
            end
            mark_change("set")
            return true, nil
        elseif section_name == "support"
            and option == "remote_mcp_server" then
            if private_session_selected() then
                env.session_remote_support[env.selected_session] = value
            else
                env.base_remote_support = value
            end
            mark_change("set")
            return true, nil
        end
        local section = find_section(section_name)
        if not section then
            return false, "section not found"
        end
        section[option] = deep_copy(value)
        mark_change("set")
        return true, nil
    end

    function cursor:set_list(_, section_name, option, value)
        env.mutation_calls = env.mutation_calls + 1
        if should_fail("set_list") then
            return false, "injected set_list failure"
        end
        local section = find_section(section_name)
        if not section then
            return false, "section not found"
        end
        section[option] = deep_copy(value)
        mark_change("set_list")
        return true, nil
    end

    function cursor:commit()
        if should_fail("commit") then
            return false, "injected commit failure"
        end
        local session_id = env.selected_session
        if not private_session_selected() then
            return false, "shared commit is forbidden in this fixture"
        end
        env.base_sections = deep_copy(env.session_views[session_id])
        env.base_support = env.session_support[session_id]
        env.base_remote_support = env.session_remote_support[session_id]
        env.session_changes[session_id] = {}
        env.commit_sessions[#env.commit_sessions + 1] = session_id
        return true, nil
    end

    function cursor:revert()
        env.revert_calls = env.revert_calls + 1
        if env.raise_revert then
            error("injected revert failure")
        end
        if env.fail_revert then
            return false, "injected revert failure"
        end
        if not private_session_selected() then
            return false, "shared revert is forbidden in this fixture"
        end
        local session_id = env.selected_session
        env.session_views[session_id] = deep_copy(env.base_sections)
        env.session_support[session_id] = env.base_support
        env.session_remote_support[session_id] = env.base_remote_support
        env.session_changes[session_id] = {}
        return true, nil
    end

    local lock = {}
    function lock:lock(command)
        if command == "tlock" and env.fail_lock then
            return false, nil, "injected lock failure"
        elseif command == "ulock" and env.raise_unlock then
            error("injected unlock failure")
        end
        if command == "ulock" then
            env.lock_released = true
        end
        return true
    end
    function lock:close()
        if env.raise_close then
            error("injected close failure")
        end
        env.lock_closed = true
        return true
    end

    local function session_ubus(object, method, data)
        env.session_calls[#env.session_calls + 1] = {
            method = method,
            data = deep_copy(data),
        }
        if object ~= "session" then
            return nil, 2, "unexpected ubus object"
        end
        if env.fail_session_method == method then
            return nil, 8, "injected " .. method .. " failure"
        end
        if method == "create" then
            env.next_session = env.next_session + 1
            local session_id = string.format("%032x", env.next_session)
            env.created_sessions[#env.created_sessions + 1] = session_id
            env.session_views[session_id] = deep_copy(env.base_sections)
            env.session_support[session_id] = env.base_support
            env.session_remote_support[session_id] =
                env.base_remote_support
            env.session_changes[session_id] = {}
            return { ubus_rpc_session = session_id }
        elseif method == "grant" then
            -- rpcd returns status 0 without a reply payload.
            return
        elseif method == "access" then
            env.access_calls[#env.access_calls + 1] = deep_copy(data)
            if data.ubus_rpc_session == env.original_session_id
                and env.deny_original_permission == data["function"] then
                return { access = false }
            end
            return { access = true }
        elseif method == "destroy" then
            if env.fail_destroy then
                return nil, 8, "injected destroy failure"
            end
            local session_id = data.ubus_rpc_session
            env.destroyed_sessions[#env.destroyed_sessions + 1] = session_id
            env.session_views[session_id] = nil
            env.session_support[session_id] = nil
            env.session_remote_support[session_id] = nil
            env.session_changes[session_id] = nil
            -- rpcd returns status 0 without a reply payload.
            return
        end
        return nil, 2, "unexpected session method"
    end

    local stubs = {
        ["luci.model.uci"] = function()
            return { cursor = function() return cursor end }
        end,
        ["luci.jsonc"] = function()
            return {
                parse = function(raw)
                    if raw == "fixture manifest" then
                        return fixture_manifest()
                    end
                    return nil
                end,
                stringify = function() return "{}" end,
            }
        end,
        ["luci.sys"] = function()
            return { exec = function() return "" end }
        end,
        ["luci.util"] = function()
            return { ubus = session_ubus }
        end,
        ["nixio.fs"] = function()
            return {
                stat = function(path)
                    if path == manifest_path or path == source_path then
                        return { type = "reg" }
                    end
                    if path == "/tmp/oasis" then
                        return { type = "dir" }
                    end
                    return nil
                end,
                readfile = function(path)
                    if path == manifest_path then
                        return "fixture manifest"
                    end
                    return nil
                end,
                access = function(path, mode)
                    return path == source_path and mode == "x"
                end,
                mkdirr = function() return true end,
                dir = function(path)
                    if path == "/etc/oasis/tool-manifest.d/"
                        and options.list_fixture_manifest then
                        local yielded = false
                        return function()
                            if not yielded then
                                yielded = true
                                return "lua.fixture.server.json"
                            end
                        end
                    end
                    return nil
                end,
            }
        end,
        ["nixio"] = function()
            return {
                open = function() return lock end,
                nanosleep = function() end,
            }
        end,
        ["oasis.common"] = function()
            return {
                db = {
                    uci = {
                        cfg = "oasis",
                        sect = { tool = "tool", support = "support" },
                    },
                },
                ai = {
                    format = {
                        output = "output",
                        chat = "chat",
                        prompt = "prompt",
                    },
                },
                file = {
                    pkg = {
                        install = "/tmp/not-present",
                        reboot_required_path = "/tmp/",
                    },
                    service = { restart_required = "/tmp/not-present" },
                },
                ubus_call = function()
                    return nil, "unexpected common.ubus_call"
                end,
            }
        end,
        ["oasis.chat.misc"] = function()
            return {
                check_file_exist = function() return false end,
                check_init_script_exists = function() return false end,
                touch = function() end,
                write_file = function() end,
            }
        end,
        ["oasis.local.tool.package.manager"] = function()
            return {
                check_process_alive = function() return false end,
                check_installed_pkg = function() return false end,
            }
        end,
        ["oasis.chat.debug"] = function()
            return {
                log = function(_, _, _, message)
                    env.logs[#env.logs + 1] = message
                end,
            }
        end,
        ["oasis.local.tool.state"] = function()
            return {
                is_control_tool = function(server, name)
                    return server == "oasis.tool.manager"
                        and (name == "get_tool_list"
                            or name == "set_tool_enabled"
                            or name == "set_tool_disabled")
                end,
            }
        end,
    }

    local module_names = {
        "oasis.local.tool.client",
        "oasis.local.tool.uci_transaction",
    }
    for name in pairs(stubs) do
        module_names[#module_names + 1] = name
    end
    local saved_loaded = {}
    local saved_preload = {}
    for _, name in ipairs(module_names) do
        saved_loaded[name] = package.loaded[name]
        saved_preload[name] = package.preload[name]
        package.loaded[name] = nil
        if stubs[name] then
            package.preload[name] = stubs[name]
        end
    end

    local loaded, client_or_err = pcall(require, "oasis.local.tool.client")

    for _, name in ipairs(module_names) do
        package.loaded[name] = saved_loaded[name]
        package.preload[name] = saved_preload[name]
    end
    if not loaded then
        error(client_or_err)
    end

    env.cursor = cursor
    return client_or_err, env
end

local function find_base_tool(env, name)
    local found = {}
    for _, section in ipairs(env.base_sections) do
        if section.name == name then
            found[#found + 1] = section
        end
    end
    return found
end

function M.register(harness)
    harness:test("unit", "manifest apply commits only an isolated UCI session", function(t)
        local client, env = new_fixture()
        local plan_ok, plan = client.build_manifest_apply_plan(manifest_path)
        t:assert_true(plan_ok)

        env.inject_shared_on_switch = true
        local applied, info = client.apply_manifest_plan(plan)
        t:assert_true(applied, tostring(info))
        t:assert_equal(1, #env.commit_sessions)
        t:assert_equal(env.created_sessions[1], env.commit_sessions[1])
        t:assert_equal(1, #env.destroyed_sessions)
        t:assert_nil(env.selected_session)
        t:assert_equal(1, #env.shared_changes,
            "concurrent shared delta must remain pending")
        t:assert_equal(1, #find_base_tool(env, "fixture_tool"))
        t:assert_equal(1, #find_base_tool(env, "custom_tool"))
        t:assert_true(env.lock_released)

        local private_sid = env.created_sessions[1]
        t:assert_equal("grant", env.session_calls[2].method)
        t:assert_deep_equal({
            ubus_rpc_session = private_sid,
            scope = "uci",
            objects = {
                { "oasis", "read" },
                { "oasis", "write" },
            },
        }, env.session_calls[2].data,
            "the private session grant must use the exact Oasis UCI scope")
        t:assert_equal(2, #env.access_calls)
        t:assert_deep_equal({
            ubus_rpc_session = private_sid,
            scope = "uci",
            object = "oasis",
            ["function"] = "read",
        }, env.access_calls[1])
        t:assert_deep_equal({
            ubus_rpc_session = private_sid,
            scope = "uci",
            object = "oasis",
            ["function"] = "write",
        }, env.access_calls[2])
    end)

    harness:test("unit", "pending Oasis UCI changes block manifest apply", function(t)
        local client, env = new_fixture()
        local plan_ok, plan = client.build_manifest_apply_plan(manifest_path)
        t:assert_true(plan_ok)
        env.shared_changes[1] = { "set", "custom", "value", "pending" }

        local applied, err = client.apply_manifest_plan(plan)
        t:assert_false(applied)
        t:assert_contains(err, "pending UCI changes")
        t:assert_equal(0, #env.created_sessions)
        t:assert_equal(0, env.mutation_calls)
        t:assert_equal(0, #env.commit_sessions)
        t:assert_equal(1, #env.shared_changes)
        t:assert_true(env.lock_released)
    end)

    harness:test("unit", "failed manifest delta cannot leak into a later apply", function(t)
        local client, env = new_fixture()
        local plan_ok, plan = client.build_manifest_apply_plan(manifest_path)
        t:assert_true(plan_ok)

        env.fail_method = "set_list"
        local first_ok, first_err = client.apply_manifest_plan(plan)
        t:assert_false(first_ok)
        t:assert_contains(first_err, "set tool section")
        t:assert_equal(0, #env.commit_sessions)
        t:assert_equal(1, #env.destroyed_sessions)
        t:assert_equal(1, #find_base_tool(env, "fixture_tool"))
        t:assert_equal(1, #find_base_tool(env, "custom_tool"))

        env.fail_method = nil
        env.failure_consumed = false
        local second_ok, second_info = client.apply_manifest_plan(plan)
        t:assert_true(second_ok, tostring(second_info))
        t:assert_equal(1, #env.commit_sessions)
        t:assert_equal(env.created_sessions[2], env.commit_sessions[1])
        t:assert_equal(2, #env.destroyed_sessions)
        t:assert_equal(1, #find_base_tool(env, "fixture_tool"))
        t:assert_equal(1, #find_base_tool(env, "custom_tool"))
    end)

    harness:test("unit", "manifest UCI operation failures are fail closed", function(t)
        for _, method in ipairs({
            "delete", "section", "set", "set_list", "commit",
        }) do
            local client, env = new_fixture()
            local plan_ok, plan = client.build_manifest_apply_plan(
                manifest_path)
            t:assert_true(plan_ok, method)
            env.fail_method = method

            local applied = client.apply_manifest_plan(plan)
            t:assert_false(applied, method)
            t:assert_equal(0, #env.commit_sessions, method)
            t:assert_equal(1, #env.destroyed_sessions, method)
            t:assert_nil(env.selected_session, method)
            t:assert_equal(1, #find_base_tool(env, "fixture_tool"), method)
            t:assert_equal(1, #find_base_tool(env, "custom_tool"), method)
        end
    end)

    harness:test("unit", "stale manifest plan is rejected before mutation", function(t)
        local client, env = new_fixture()
        local plan_ok, plan = client.build_manifest_apply_plan(manifest_path)
        t:assert_true(plan_ok)
        find_base_tool(env, "fixture_tool")[1].enable = "0"

        local applied, err = client.apply_manifest_plan(plan)
        t:assert_false(applied)
        t:assert_contains(err, "plan changed")
        t:assert_equal(0, env.mutation_calls)
        t:assert_equal(0, #env.commit_sessions)
        t:assert_equal(1, #env.destroyed_sessions)
    end)

    harness:test("unit", "cleanup loss after commit does not request a retry", function(t)
        local client, env = new_fixture()
        local plan_ok, plan = client.build_manifest_apply_plan(manifest_path)
        t:assert_true(plan_ok)
        env.fail_destroy = true

        local applied, info = client.apply_manifest_plan(plan)
        t:assert_true(applied)
        t:assert_type("table", info)
        t:assert_contains(info.warning, "destroy isolated UCI session")
        t:assert_equal(1, #env.commit_sessions)
        t:assert_nil(env.selected_session)
    end)

    harness:test("unit", "restored manifest reconciliation preserves disabled support and custom tools", function(t)
        local client, env = new_fixture({ base_support = "0" })
        local applied, info = client.apply_manifest_file(manifest_path, {
            preserve_local_tool_support = true,
        })
        t:assert_true(applied, tostring(info))
        t:assert_equal("0", env.base_support)
        t:assert_equal("0", env.base_remote_support)
        t:assert_equal(1, #find_base_tool(env, "fixture_tool"))
        t:assert_equal("1", find_base_tool(env, "fixture_tool")[1].enable)
        t:assert_equal("1", find_base_tool(env, "custom_tool")[1].enable)
        t:assert_equal(1, #env.commit_sessions)
        t:assert_equal(env.created_sessions[1], env.commit_sessions[1])
        t:assert_nil(env.selected_session)
    end)

    harness:test("unit", "remote MCP support uses the isolated transaction", function(t)
        local client, env = new_fixture()
        env.inject_shared_on_switch = true

        local applied, info = client.enable_remote_mcp_support()
        t:assert_true(applied, tostring(info))
        t:assert_true(info.changed)
        t:assert_equal("1", env.base_remote_support)
        t:assert_equal(1, #env.commit_sessions)
        t:assert_equal(env.created_sessions[1], env.commit_sessions[1])
        t:assert_equal(1, #env.shared_changes,
            "concurrent shared delta must remain pending")
        t:assert_equal(1, #env.destroyed_sessions)
        t:assert_nil(env.selected_session)
        t:assert_true(env.lock_released)
    end)

    harness:test("unit", "empty registry refresh adds manifests without delete-by-type", function(t)
        local client, env = new_fixture({
            base_sections = {},
            base_support = "0",
            list_fixture_manifest = true,
        })
        env.inject_shared_on_switch = true

        local refreshed, info = client.update_server_info()
        t:assert_true(refreshed, tostring(info))
        t:assert_equal(1, info.count)
        t:assert_equal(0, env.delete_all_calls,
            "empty rpcd registries reject delete-by-type")
        t:assert_equal(1, #env.commit_sessions)
        t:assert_equal(env.created_sessions[1], env.commit_sessions[1])
        t:assert_equal(1, #env.shared_changes,
            "a concurrent shared delta must remain pending")
        t:assert_equal(1, #find_base_tool(env, "fixture_tool"))
        t:assert_equal("1", env.base_support)
        t:assert_equal(1, #env.destroyed_sessions)
        t:assert_true(env.lock_released)
    end)

    harness:test("unit", "authenticated source session needs Oasis read and write access", function(t)
        for _, permission in ipairs({ "read", "write" }) do
            local original_sid = string.rep(
                permission == "read" and "a" or "b", 32)
            local client, env = new_fixture({
                original_session_id = original_sid,
            })
            local plan_ok, plan = client.build_manifest_apply_plan(
                manifest_path)
            t:assert_true(plan_ok, permission)
            env.deny_original_permission = permission

            local applied, err = client.apply_manifest_plan(plan)
            t:assert_false(applied, permission)
            t:assert_contains(err, "lacks " .. permission .. " access",
                permission)
            t:assert_equal(permission == "read" and 1 or 2,
                #env.access_calls, permission)
            t:assert_equal(original_sid,
                env.access_calls[1].ubus_rpc_session, permission)
            t:assert_equal("uci", env.access_calls[1].scope, permission)
            t:assert_equal("oasis", env.access_calls[1].object, permission)
            t:assert_equal("read", env.access_calls[1]["function"],
                permission)
            t:assert_equal(0, #env.created_sessions, permission)
            t:assert_equal(0, env.mutation_calls, permission)
            t:assert_equal(original_sid, env.selected_session, permission)
            t:assert_true(env.lock_released, permission)
        end
    end)

    harness:test("unit", "isolated session setup failures are fail closed", function(t)
        for _, method in ipairs({ "create", "grant", "access" }) do
            local client, env = new_fixture()
            local plan_ok, plan = client.build_manifest_apply_plan(
                manifest_path)
            t:assert_true(plan_ok, method)
            env.fail_session_method = method

            local applied = client.apply_manifest_plan(plan)
            t:assert_false(applied, method)
            t:assert_equal(0, env.mutation_calls, method)
            t:assert_equal(0, #env.commit_sessions, method)
            t:assert_nil(env.selected_session, method)
            t:assert_true(env.lock_released, method)
            if method == "create" then
                t:assert_equal(0, #env.destroyed_sessions, method)
            else
                t:assert_equal(1, #env.destroyed_sessions, method)
            end
        end
    end)

    harness:test("unit", "failed session selection never reverts shared state", function(t)
        local client, env = new_fixture()
        local plan_ok, plan = client.build_manifest_apply_plan(manifest_path)
        t:assert_true(plan_ok)
        env.fail_select = true

        local applied, err = client.apply_manifest_plan(plan)
        t:assert_false(applied)
        t:assert_contains(err, "select isolated UCI session")
        t:assert_equal(0, env.revert_calls,
            "the original session must never be reverted")
        t:assert_equal(0, env.mutation_calls)
        t:assert_equal(1, #env.destroyed_sessions)
        t:assert_nil(env.selected_session)
        t:assert_true(env.lock_released)
    end)

    harness:test("unit", "raised callback still restores destroys and unlocks", function(t)
        local client, env = new_fixture()
        local plan_ok, plan = client.build_manifest_apply_plan(manifest_path)
        t:assert_true(plan_ok)
        env.raise_private_foreach = true

        local applied, err = client.apply_manifest_plan(plan)
        t:assert_false(applied)
        t:assert_contains(err, "transaction failed")
        t:assert_equal(1, env.revert_calls)
        t:assert_equal(1, #env.destroyed_sessions)
        t:assert_nil(env.selected_session)
        t:assert_true(env.lock_released)
        t:assert_true(env.lock_closed)
    end)

    harness:test("unit", "raised revert cannot interrupt final cleanup", function(t)
        local client, env = new_fixture()
        local plan_ok, plan = client.build_manifest_apply_plan(manifest_path)
        t:assert_true(plan_ok)
        env.fail_method = "set_list"
        env.raise_revert = true

        local applied, err = client.apply_manifest_plan(plan)
        t:assert_false(applied)
        t:assert_contains(err, "discard isolated UCI changes")
        t:assert_equal(1, env.revert_calls)
        t:assert_equal(1, #env.destroyed_sessions)
        t:assert_nil(env.selected_session)
        t:assert_true(env.lock_released)
        t:assert_true(env.lock_closed)
    end)

    harness:test("unit", "raised restore and unlock become success warnings", function(t)
        for _, method in ipairs({ "restore", "unlock" }) do
            local client, env = new_fixture()
            local plan_ok, plan = client.build_manifest_apply_plan(
                manifest_path)
            t:assert_true(plan_ok, method)
            if method == "restore" then
                env.raise_restore = true
            else
                env.raise_unlock = true
            end

            local applied, info = client.apply_manifest_plan(plan)
            t:assert_true(applied, method)
            t:assert_type("table", info, method)
            t:assert_type("string", info.warning, method)
            t:assert_equal(1, #env.commit_sessions, method)
            t:assert_equal(1, #env.destroyed_sessions, method)
            t:assert_true(env.lock_closed, method)
            if method == "restore" then
                t:assert_contains(info.warning, "restore", method)
            else
                t:assert_contains(info.warning, "unlock", method)
            end
        end
    end)

    harness:test("unit", "raised lock close becomes a success warning", function(t)
        local client, env = new_fixture()
        local plan_ok, plan = client.build_manifest_apply_plan(manifest_path)
        t:assert_true(plan_ok)
        env.raise_close = true

        local applied, info = client.apply_manifest_plan(plan)
        t:assert_true(applied)
        t:assert_type("table", info)
        t:assert_contains(info.warning,
            "failed to close UCI transaction lock")
        t:assert_equal(1, #env.commit_sessions)
        t:assert_equal(1, #env.destroyed_sessions)
        t:assert_nil(env.selected_session)
        t:assert_true(env.lock_released,
            "the lock must be unlocked before close is attempted")
        t:assert_nil(env.lock_closed)
    end)

    harness:test("unit", "busy global transaction lock blocks all mutation", function(t)
        local client, env = new_fixture()
        local plan_ok, plan = client.build_manifest_apply_plan(manifest_path)
        t:assert_true(plan_ok)
        env.fail_lock = true

        local applied, err = client.apply_manifest_plan(plan)
        t:assert_false(applied)
        t:assert_contains(err, "already in progress")
        t:assert_equal(0, #env.created_sessions)
        t:assert_equal(0, env.mutation_calls)
        t:assert_equal(0, #env.commit_sessions)
        t:assert_true(env.lock_closed)
    end)
end

return M
