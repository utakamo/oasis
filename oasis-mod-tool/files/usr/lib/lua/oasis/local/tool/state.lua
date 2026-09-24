local M = {}

-- Read-only compatibility marker used by the core sequence controller before
-- it exposes the Tool Search management tools.
M.TOOL_SEARCH_ABI = 2

local CONFIG = "oasis"
local TOOL_SECTION_TYPE = "tool"
local CONTROL_SERVER = "oasis.tool.manager"
local CONTROL_TOOLS = {
    get_tool_list = true,
    set_tool_disabled = true,
    set_tool_enabled = true,
}

local function is_nonempty_string(value)
    return type(value) == "string" and value ~= ""
end

local function failure(code, message, server_name, tool_name)
    return {
        status = "NG",
        changed = false,
        code = code,
        error = message,
        server = server_name,
        tool = tool_name,
    }
end

local function normalized_enable(value)
    if value == true or value == 1 or value == "1" then
        return "1"
    end
    return "0"
end

local function ensure_clean_config(uci, server_name, tool_name)
    if not uci or type(uci.changes) ~= "function" then
        return nil, failure(
            "uci_changes_failed",
            "Failed to inspect pending Oasis configuration changes.",
            server_name,
            tool_name
        )
    end

    local ok, changes = pcall(uci.changes, uci, CONFIG)
    if not ok or type(changes) ~= "table" then
        return nil, failure(
            "uci_changes_failed",
            "Failed to inspect pending Oasis configuration changes.",
            server_name,
            tool_name
        )
    end

    -- luci.model.uci:commit(config) commits every saved delta for that config,
    -- not just the option changed by this module. Refuse to stage our change
    -- when this UCI session already owns any other `oasis` delta.
    if next(changes) ~= nil then
        return nil, failure(
            "uci_pending_changes",
            "Uncommitted Oasis configuration changes already exist.",
            server_name,
            tool_name
        )
    end

    return true
end

local function collect_tools(uci)
    if not uci or type(uci.foreach) ~= "function" then
        return nil, failure("invalid_uci_cursor", "A UCI cursor is required.")
    end

    local tools = {}
    local ok, foreach_result, foreach_error = pcall(function()
        return uci:foreach(CONFIG, TOOL_SECTION_TYPE, function(section)
            local enable = normalized_enable(section.enable)
            local conflict = normalized_enable(section.conflict)
            local tool = {}
            for key, value in pairs(section) do tool[key] = value end
            tool.section = tostring(section[".name"] or "")
            tool.server = tostring(section.server or "")
            tool.name = tostring(section.name or "")
            tool.description = tostring(section.description or "")
            tool.enable, tool.enabled = enable, enable == "1"
            tool.conflict, tool.conflicted = conflict, conflict == "1"
            tools[#tools + 1] = tool
        end)
    end)

    -- luci.model.uci returns false,nil for a valid but empty result and
    -- false,<message> when the ubus read itself fails.
    if not ok or (foreach_result == false and foreach_error ~= nil) then
        return nil, failure("uci_read_failed", "Failed to read the tool configuration.")
    end

    -- Never trust a possibly stale `conflict` option as the sole source of
    -- truth. Function Calling addresses tools by name only, so duplicate names
    -- are ambiguous even when they belong to different ubus servers.
    local name_counts = {}
    for _, tool in ipairs(tools) do
        name_counts[tool.name] = (name_counts[tool.name] or 0) + 1
    end
    for _, tool in ipairs(tools) do
        if tool.name ~= "" and name_counts[tool.name] > 1 then
            tool.conflict = "1"
            tool.conflicted = true
        end
    end

    return tools
end

local function compare_tools(left, right)
    if left.server ~= right.server then
        return left.server < right.server
    end
    if left.name ~= right.name then
        return left.name < right.name
    end
    if left.description ~= right.description then
        return left.description < right.description
    end
    if left.enable ~= right.enable then
        return left.enable < right.enable
    end
    return left.section < right.section
end

function M.is_control_tool(server_name, tool_name)
    return server_name == CONTROL_SERVER and CONTROL_TOOLS[tool_name] == true
end

function M.list(uci)
    local tools, err = collect_tools(uci)
    if not tools then
        err.tool = {}
        return err
    end

    table.sort(tools, compare_tools)

    local result = {}
    for _, tool in ipairs(tools) do
        result[#result + 1] = {
            server = tool.server,
            name = tool.name,
            description = tool.description,
            enable = tool.enable,
            enabled = tool.enabled,
            conflict = tool.conflict,
            conflicted = tool.conflicted,
        }
    end

    return {
        status = "OK",
        tool = result,
    }
end

local function set_enabled_internal(
    uci, server_name, tool_name, desired, options, commit_directly)
    options = options or {}

    if options.manual_only then
        local mode, err = M.get_mode(uci)
        if not mode then return err end
        if mode.auto_mode then
            return failure("auto_mode_active", "Manual tool settings cannot be changed in Auto mode.")
        end
        if M.is_control_tool(server_name, tool_name) then
            return failure("protected_control_tool", "Use the Auto mode switch to manage Tool Search tools.")
        end
    end

    if not is_nonempty_string(server_name) then
        return failure("missing_server", "The server name is required.", server_name, tool_name)
    end
    if not is_nonempty_string(tool_name) then
        return failure("missing_tool", "The tool name is required.", server_name, tool_name)
    end
    if desired ~= true and desired ~= false
        and desired ~= 1 and desired ~= 0
        and desired ~= "1" and desired ~= "0"
    then
        return failure(
            "invalid_enable",
            "The enabled state must be true, false, 1, or 0.",
            server_name,
            tool_name
        )
    end

    local desired_enable = normalized_enable(desired)
    local tools, err = collect_tools(uci)
    if not tools then
        err.server = server_name
        err.tool = tool_name
        return err
    end

    local matches = {}
    for _, tool in ipairs(tools) do
        if tool.server == server_name and tool.name == tool_name then
            matches[#matches + 1] = tool
        end
    end

    if #matches == 0 then
        return failure(
            "tool_not_found",
            "No tool matches the specified server and name.",
            server_name,
            tool_name
        )
    end
    if #matches > 1 then
        return failure(
            "duplicate_tool",
            "Multiple tool sections match the specified server and name.",
            server_name,
            tool_name
        )
    end

    local target = matches[1]
    if target.conflicted then
        return failure(
            "tool_conflict",
            "The tool is marked as conflicted and cannot be changed.",
            server_name,
            tool_name
        )
    end
    if desired_enable == "0"
        and not options.allow_control_disable
        and M.is_control_tool(server_name, tool_name)
    then
        return failure(
            "protected_control_tool",
            "Tool Search control tools cannot disable themselves.",
            server_name,
            tool_name
        )
    end

    if target.enable == desired_enable then
        return {
            status = "OK",
            changed = false,
            server = server_name,
            tool = tool_name,
            enable = desired_enable,
            enabled = (desired_enable == "1"),
        }
    end

    if commit_directly then
        local clean, changes_err = ensure_clean_config(
            uci,
            server_name,
            tool_name
        )
        if not clean then
            return changes_err
        end
    end

    local set_ok, set_result = pcall(
        uci.set,
        uci,
        CONFIG,
        target.section,
        "enable",
        desired_enable
    )
    if not set_ok or set_result ~= true then
        return failure(
            "uci_set_failed",
            "Failed to update the tool configuration.",
            server_name,
            tool_name
        )
    end

    if not commit_directly then
        return {
            status = "OK",
            changed = true,
            server = server_name,
            tool = tool_name,
            enable = desired_enable,
            enabled = (desired_enable == "1"),
        }
    end

    local commit_ok, commit_result = pcall(uci.commit, uci, CONFIG)
    if not commit_ok or commit_result ~= true then
        -- The rpcd-backed LuCI cursor stages a successful set before commit.
        -- Do not call revert(CONFIG): it is config-wide and could discard an
        -- unrelated delta staged after our clean-state check. Instead append
        -- the old value, preserving all other deltas while neutralizing ours.
        local restore_ok, restore_result = pcall(
            uci.set,
            uci,
            CONFIG,
            target.section,
            "enable",
            target.enable
        )
        if not restore_ok or restore_result ~= true then
            return failure(
                "uci_rollback_failed",
                "Failed to commit or roll back the tool configuration.",
                server_name,
                tool_name
            )
        end
        return failure(
            "uci_commit_failed",
            "Failed to commit the tool configuration.",
            server_name,
            tool_name
        )
    end

    return {
        status = "OK",
        changed = true,
        server = server_name,
        tool = tool_name,
        enable = desired_enable,
        enabled = (desired_enable == "1"),
    }
end

function M.set_enabled(uci, server_name, tool_name, desired, options)
    return set_enabled_internal(
        uci, server_name, tool_name, desired, options, true)
end

local function set_enabled_by_name_internal(
    uci, tool_name, desired, options, commit_directly)
    if not is_nonempty_string(tool_name) then
        return failure("missing_tool", "The tool name is required.", nil, tool_name)
    end

    local tools, err = collect_tools(uci)
    if not tools then
        err.tool = tool_name
        return err
    end

    local matches = {}
    for _, tool in ipairs(tools) do
        if tool.name == tool_name then
            matches[#matches + 1] = tool
        end
    end

    if #matches == 0 then
        return failure("tool_not_found", "No tool matches the specified name.", nil, tool_name)
    end
    if #matches > 1 then
        return failure(
            "duplicate_tool",
            "The tool name is not unique; specify its server as well.",
            nil,
            tool_name
        )
    end

    return set_enabled_internal(
        uci,
        matches[1].server,
        tool_name,
        desired,
        options,
        commit_directly
    )
end

function M.set_enabled_by_name(uci, tool_name, desired, options)
    return set_enabled_by_name_internal(
        uci, tool_name, desired, options, true)
end

local function run_persistent(
    uci, server_name, tool_name, transaction_callback)
    local loaded, transaction = pcall(
        require, "oasis.local.tool.uci_transaction")
    if not loaded or type(transaction) ~= "table"
        or type(transaction.run) ~= "function" then
        return failure(
            "uci_transaction_unavailable",
            "The isolated UCI transaction service is unavailable.",
            server_name,
            tool_name
        )
    end

    local called, ok, result, code = pcall(transaction.run, {
        cursor = uci,
        config = CONFIG,
        label = "Oasis tool state",
    }, function(private_uci)
        local state_result = transaction_callback(private_uci)
        return state_result.status == "OK",
            state_result,
            state_result.code
    end)
    if not called then
        return failure(
            "uci_transaction_failed",
            "The isolated UCI transaction failed.",
            server_name,
            tool_name
        )
    end
    if type(result) == "table" then
        return result
    end
    if ok then
        return failure(
            "uci_transaction_failed",
            "The isolated UCI transaction returned no result.",
            server_name,
            tool_name
        )
    end

    return failure(
        code or "uci_transaction_failed",
        tostring(result or "The isolated UCI transaction failed."),
        server_name,
        tool_name
    )
end

function M.set_enabled_persistent(
    uci, server_name, tool_name, desired, options)
    return run_persistent(uci, server_name, tool_name, function(private_uci)
        return set_enabled_internal(
            private_uci,
            server_name,
            tool_name,
            desired,
            options,
            false
        )
    end)
end

function M.set_enabled_by_name_persistent(uci, tool_name, desired, options)
    return run_persistent(uci, nil, tool_name, function(private_uci)
        return set_enabled_by_name_internal(
            private_uci,
            tool_name,
            desired,
            options,
            false
        )
    end)
end

-- Missing options on existing installations deliberately mean Manual mode.
-- Read both values in one UCI response to avoid a torn mode/generation pair.
function M.get_mode(uci)
    local ok, support = pcall(uci.get_all, uci, CONFIG, "support")
    if not ok or type(support) ~= "table" then
        return nil, failure("uci_read_failed", "Failed to read the tool mode configuration.")
    end
    local flag = support.tool_auto or "0"
    local generation = support.tool_auto_generation or "0"
    if (flag ~= "0" and flag ~= "1") or type(generation) ~= "string"
        or not generation:match("^%d+$") or #generation > 12 then
        return nil, failure("invalid_tool_mode", "Invalid Auto mode configuration.")
    end
    return { auto_mode = flag == "1", token = flag .. ":" .. generation,
        generation = tonumber(generation) }
end

local function tool_key(tool)
    return #tool.server .. ":" .. tool.server .. tool.name
end

local function fingerprint(tool)
    -- Exclude the UCI section ID and mutable enable/conflict flags. Retain all
    -- definition/source fields so a replaced tool does not inherit permission.
    local definition = {}
    for _, key in ipairs({ "server", "name", "type", "description", "property",
        "required", "additionalProperties", "script", "source_type", "source_path",
        "manifest_path", "timeout", "execution_message", "download_message" }) do
        definition[key] = tool[key]
    end
    return require("oasis.chat.function.calling.policy").canonical_object(definition)
end

function M.snapshot(uci, expected_token)
    local mode, err = M.get_mode(uci)
    if not mode then return nil, err end
    if expected_token and mode.token ~= expected_token then
        return nil, failure("tool_mode_changed", "Tool mode changed. Start a new request.")
    end
    local tools
    tools, err = collect_tools(uci)
    if not tools then return nil, err end
    local stored
    if mode.auto_mode then
        stored, err = require("oasis.local.tool.auto_store").read()
        if not stored then return nil, failure("auto_state_failed", err) end
    end
    for _, tool in ipairs(tools) do
        tool.manual_enable = tool.enable
        local control = M.is_control_tool(tool.server, tool.name)
        local reserved = CONTROL_TOOLS[tool.name] == true
        local enabled
        if mode.auto_mode then
            local signature = not control and fingerprint(tool) or nil
            enabled = control or (signature ~= nil
                and stored.enabled[tool_key(tool)] == signature)
        else
            enabled = not control and tool.enable == "1"
        end
        enabled = enabled and not tool.conflicted and tool.name ~= ""
            and tool.server ~= "" and (not reserved or control)
        tool.enable, tool.enabled = enabled and "1" or "0", enabled == true
    end
    -- Recheck after the registry / runtime read, especially during a mode flip.
    local latest
    latest, err = M.get_mode(uci)
    if not latest then return nil, err end
    if latest.token ~= mode.token then
        return nil, failure("tool_mode_changed", "Tool mode changed. Start a new request.")
    end
    return { tools = tools, auto_mode = mode.auto_mode, token = mode.token }
end

function M.list_effective(uci)
    local snapshot, err = M.snapshot(uci)
    if not snapshot then return err end
    table.sort(snapshot.tools, compare_tools)
    local tools = {}
    for _, tool in ipairs(snapshot.tools) do
        tools[#tools + 1] = { server = tool.server, name = tool.name,
            description = tool.description, enable = tool.enable,
            enabled = tool.enabled, conflict = tool.conflict,
            conflicted = tool.conflicted }
    end
    return { status = "OK", auto_mode = snapshot.auto_mode, tool = tools }
end

local function auto_locked(callback)
    local result, err = require("oasis.local.tool.auto_store").with_lock(callback)
    return result or failure("auto_state_failed", err)
end

function M.set_auto_mode(uci, desired)
    if desired ~= "0" and desired ~= "1" then
        return failure("invalid_enable", "Auto mode must be 0 or 1.")
    end
    return auto_locked(function()
        return run_persistent(uci, nil, nil, function(private_uci)
            local mode, err = M.get_mode(private_uci)
            if not mode then return err end
            if mode.auto_mode == (desired == "1") then
                return { status = "OK", changed = false, auto_mode = mode.auto_mode }
            end
            if desired == "1" then
                local tools
                tools, err = collect_tools(private_uci)
                if not tools then return err end
                local controls = {}
                for _, tool in ipairs(tools) do
                    if M.is_control_tool(tool.server, tool.name) and not tool.conflicted then
                        controls[tool.name] = true
                    end
                end
                for name in pairs(CONTROL_TOOLS) do
                    if not controls[name] then
                        return failure("control_tools_unavailable", "Refresh tools before enabling Auto mode.")
                    end
                end
            end
            if mode.generation >= 999999999999
                or private_uci:set(CONFIG, "support", "tool_auto", desired) ~= true
                or private_uci:set(CONFIG, "support", "tool_auto_generation",
                    string.format("%.0f", mode.generation + 1)) ~= true then
                return failure("uci_set_failed", "Failed to update Auto mode.")
            end
            return { status = "OK", changed = true, auto_mode = desired == "1" }
        end)
    end)
end

function M.set_auto_enabled(uci, server_name, tool_name, desired)
    if not is_nonempty_string(server_name) or not is_nonempty_string(tool_name)
        or (desired ~= true and desired ~= false) then
        return failure("invalid_target", "An exact server, tool and boolean state are required.")
    end
    if CONTROL_TOOLS[tool_name] then
        return failure("protected_control_tool", "Auto mode manages Tool Search tools automatically.")
    end
    return auto_locked(function()
        local snapshot, err = M.snapshot(uci)
        if not snapshot then return err end
        if not snapshot.auto_mode then
            return failure("auto_mode_disabled", "Tool Search is available only in Auto mode.")
        end
        local target
        for _, tool in ipairs(snapshot.tools) do
            if tool.server == server_name and tool.name == tool_name then
                if tool.conflicted or target then
                    return failure("tool_conflict", "The tool name is ambiguous or conflicted.")
                end
                target = tool
            end
        end
        if not target then return failure("tool_not_found", "No tool matches the server and name.") end
        local store = require("oasis.local.tool.auto_store")
        local stored
        stored, err = store.read()
        if not stored then return failure("auto_state_failed", err) end
        local signature = fingerprint(target)
        if not signature then return failure("invalid_tool", "Invalid tool definition.") end
        local changed = target.enabled ~= desired
        if changed then
            stored.enabled[tool_key(target)] = desired and signature or nil
            local written
            written, err = store.write(stored)
            if not written then return failure("auto_state_failed", err) end
        end
        return { status = "OK", changed = changed, server = server_name,
            tool = tool_name, enable = desired and "1" or "0", enabled = desired }
    end)
end

return M
