local util = require("luci.util")
local nixio = require("nixio")
local fs = require("nixio.fs")

local M = {}

local DEFAULT_LOCK_PATH = "/tmp/oasis/uci-transaction.lock"
local DEFAULT_SESSION_TIMEOUT = 60

local function add_cleanup_warning(value, warning)
    if type(value) == "table" then
        if value.warning and value.warning ~= "" then
            value.warning = tostring(value.warning) .. "; " .. warning
        else
            value.warning = warning
        end
        return value
    end

    if value == nil then
        return warning
    end
    return tostring(value) .. "; " .. warning
end

local function session_call(method, data)
    -- rpcd session.grant and session.destroy deliberately return no payload.
    -- luci.util.ubus therefore returns no values on success, while a ubus
    -- status error is returned as nil, numeric-code, message.
    local called, result, code, message = pcall(
        util.ubus, "session", method, data or {})
    if not called then
        return nil, tostring(result or ("session " .. method .. " failed"))
    end
    if result == nil and code ~= nil then
        return nil, tostring(message or code)
    end
    if result ~= nil and type(result) ~= "table" then
        return nil, "invalid session " .. method .. " response"
    end
    return result or {}, nil
end

local function acquire_lock(path)
    if not fs.stat("/tmp/oasis") then
        if type(fs.mkdirr) ~= "function" or not fs.mkdirr("/tmp/oasis") then
            return nil, "failed to create UCI transaction lock directory"
        end
    end

    local lock, _, open_err = nixio.open(path, "a", "0600")
    if not lock then
        return nil, "failed to open UCI transaction lock: "
            .. tostring(open_err or "unknown error")
    end

    local locked, _, lock_err = lock:lock("tlock")
    if not locked then
        local close_called, close_result = pcall(lock.close, lock)
        if not close_called or close_result ~= true then
            lock_err = tostring(lock_err or "lock busy")
                .. "; failed to close unowned UCI transaction lock: "
                .. tostring(close_called and close_result
                    or close_result or "unknown error")
        end
        return nil, "another Oasis UCI transaction is already in progress: "
            .. tostring(lock_err or "lock busy")
    end

    return lock, nil
end

local function release_lock(lock)
    if not lock then
        return true, nil
    end

    local errors = {}
    local unlock_called, unlocked, _, unlock_err = pcall(
        lock.lock, lock, "ulock")
    if not unlock_called or not unlocked then
        errors[#errors + 1] = "failed to unlock UCI transaction: "
            .. tostring(unlock_called and unlock_err
                or unlocked or "unknown error")
    end
    local close_called, closed, _, close_err = pcall(lock.close, lock)
    if not close_called or closed == false or closed == nil then
        errors[#errors + 1] = "failed to close UCI transaction lock: "
            .. tostring(close_called and close_err
                or closed or "unknown error")
    end

    if #errors > 0 then
        return false, table.concat(errors, "; ")
    end
    return true, nil
end

local function check_access(session_id, config, permission, label)
    local access, access_err = session_call("access", {
        ubus_rpc_session = session_id,
        scope = "uci",
        object = config,
        ["function"] = permission,
    })
    if not access or access.access ~= true then
        return false, string.format(
            "%s lacks %s access to UCI config %s: %s",
            label,
            permission,
            config,
            tostring(access_err or "permission denied"))
    end
    return true, nil
end

local function destroy_session(session_id)
    if not session_id then
        return true, nil
    end

    local destroyed, destroy_err = session_call("destroy", {
        ubus_rpc_session = session_id,
    })
    if not destroyed then
        return false, "failed to destroy isolated UCI session: "
            .. tostring(destroy_err)
    end
    return true, nil
end

local function inspect_changes(cursor, config, label)
    local called, changes, changes_err = pcall(cursor.changes, cursor, config)
    if not called or type(changes) ~= "table" then
        return nil, "failed to inspect " .. label .. " UCI changes: "
            .. tostring(changes_err or changes or "unknown UCI error")
    end
    return changes, nil
end

-- Run one config-wide UCI mutation in an rpcd-private delta directory.
-- The callback must only stage changes and return `true, value` on success;
-- this helper performs the single authoritative commit.
function M.run(options, callback)
    options = options or {}
    local cursor = options.cursor
    local config = options.config
    local label = type(options.label) == "string"
        and options.label ~= "" and options.label or "Oasis"
    local timeout = tonumber(options.timeout) or DEFAULT_SESSION_TIMEOUT
    if timeout < 1 then
        timeout = DEFAULT_SESSION_TIMEOUT
    end

    if type(cursor) ~= "table" or type(config) ~= "string"
        or config == "" or type(callback) ~= "function" then
        return false, "invalid UCI transaction request", "invalid_transaction"
    end
    if type(cursor.get_session_id) ~= "function"
        or type(cursor.set_session_id) ~= "function"
        or type(cursor.changes) ~= "function"
        or type(cursor.commit) ~= "function"
        or type(cursor.revert) ~= "function"
    then
        return false,
            "installed LuCI UCI client lacks session isolation",
            "uci_session_unsupported"
    end

    local lock_called, lock, lock_err = pcall(
        acquire_lock, DEFAULT_LOCK_PATH)
    if not lock_called or not lock then
        return false,
            tostring(lock_called and lock_err or lock or "lock failure"),
            "uci_lock_failed"
    end

    local previous_session_id
    local isolated_session_id
    local switch_attempted = false
    local session_selected = false
    local operation_ok = false
    local value_or_error
    local error_code
    local committed = false

    local call_ok, raised_error = pcall(function()
        previous_session_id = cursor:get_session_id()
        if previous_session_id ~= nil
            and (type(previous_session_id) ~= "string"
                or previous_session_id == "") then
            value_or_error = "invalid previous UCI session identifier"
            error_code = "uci_session_invalid"
            return
        end

        -- A LuCI controller runs with the authenticated browser session set on
        -- the module-global cursor. Verify that session before granting a new
        -- private one, otherwise this helper could bypass the caller's ACL.
        if previous_session_id then
            for _, permission in ipairs({ "read", "write" }) do
                local allowed, access_err = check_access(
                    previous_session_id,
                    config,
                    permission,
                    "original UCI session")
                if not allowed then
                    value_or_error = access_err
                    error_code = "uci_original_access_denied"
                    return
                end
            end
        end

        local pending, pending_err = inspect_changes(
            cursor, config, "existing " .. label)
        if not pending then
            value_or_error = pending_err
            error_code = "uci_changes_failed"
            return
        end
        if next(pending) ~= nil then
            value_or_error = label
                .. " has pending UCI changes; refusing to commit them"
            error_code = "uci_pending_changes"
            return
        end

        local created, create_err = session_call("create", {
            timeout = timeout,
        })
        if not created then
            value_or_error = "failed to create isolated UCI session: "
                .. tostring(create_err)
            error_code = "uci_session_create_failed"
            return
        end

        isolated_session_id = created.ubus_rpc_session
        if type(isolated_session_id) ~= "string"
            or #isolated_session_id ~= 32
            or not isolated_session_id:match("^%x+$") then
            isolated_session_id = nil
            value_or_error = "invalid isolated UCI session response"
            error_code = "uci_session_invalid"
            return
        end

        local granted, grant_err = session_call("grant", {
            ubus_rpc_session = isolated_session_id,
            scope = "uci",
            objects = {
                { config, "read" },
                { config, "write" },
            },
        })
        if not granted then
            value_or_error = "failed to grant isolated UCI session access: "
                .. tostring(grant_err)
            error_code = "uci_session_grant_failed"
            return
        end

        for _, permission in ipairs({ "read", "write" }) do
            local allowed, access_err = check_access(
                isolated_session_id,
                config,
                permission,
                "isolated UCI session")
            if not allowed then
                value_or_error = access_err
                error_code = "uci_session_access_denied"
                return
            end
        end

        switch_attempted = true
        local switched, switch_err = cursor:set_session_id(
            isolated_session_id)
        if switched ~= true then
            value_or_error = "failed to select isolated UCI session: "
                .. tostring(switch_err or "unknown error")
            error_code = "uci_session_select_failed"
            return
        end
        session_selected = true

        local isolated_changes, isolated_changes_err = inspect_changes(
            cursor, config, "isolated " .. label)
        if not isolated_changes then
            value_or_error = isolated_changes_err
            error_code = "uci_changes_failed"
            return
        end
        if next(isolated_changes) ~= nil then
            value_or_error = "isolated UCI session is not clean"
            error_code = "uci_session_dirty"
            return
        end

        local callback_ok, callback_result, callback_value, callback_code =
            pcall(callback, cursor)
        if not callback_ok then
            value_or_error = label .. " UCI transaction failed: "
                .. tostring(callback_result)
            error_code = "uci_callback_failed"
            return
        end
        if callback_result ~= true then
            value_or_error = callback_value or (label .. " UCI mutation failed")
            error_code = callback_code or "uci_mutation_failed"
            return
        end

        local staged, staged_err = inspect_changes(
            cursor, config, "staged " .. label)
        if not staged then
            value_or_error = staged_err
            error_code = "uci_changes_failed"
            return
        end

        if next(staged) ~= nil then
            local commit_ok, commit_err = cursor:commit(config)
            if commit_ok ~= true then
                value_or_error = "failed to commit " .. label
                    .. " UCI changes: "
                    .. tostring(commit_err or "unknown UCI error")
                error_code = "uci_commit_failed"
                return
            end
            committed = true
        end

        operation_ok = true
        value_or_error = callback_value
    end)

    if not call_ok then
        operation_ok = false
        value_or_error = label .. " UCI transaction failed: "
            .. tostring(raised_error)
        error_code = "uci_transaction_failed"
    end

    local cleanup_errors = {}
    if isolated_session_id and not operation_ok and session_selected then
        local revert_called, reverted, revert_err = pcall(
            cursor.revert, cursor, config)
        if not revert_called or reverted ~= true then
            cleanup_errors[#cleanup_errors + 1] =
                "failed to discard isolated UCI changes: "
                .. tostring(revert_called and revert_err
                    or reverted or "unknown UCI error")
        end
    end

    if switch_attempted then
        local restore_called, restored, restore_err = pcall(
            cursor.set_session_id, cursor, previous_session_id)
        if not restore_called or restored ~= true then
            cleanup_errors[#cleanup_errors + 1] =
                "failed to restore the previous UCI session: "
                .. tostring(restore_called and restore_err
                    or restored or "unknown error")
        end
    end

    local destroyed, destroy_err = destroy_session(isolated_session_id)
    if not destroyed then
        cleanup_errors[#cleanup_errors + 1] = destroy_err
    end

    local released, release_err = release_lock(lock)
    if not released then
        cleanup_errors[#cleanup_errors + 1] = release_err
    end

    if #cleanup_errors > 0 then
        local warning = table.concat(cleanup_errors, "; ")
        if operation_ok then
            -- A successful commit is authoritative. A cleanup-only failure
            -- must not invite callers to retry a mutation that already landed.
            return true, add_cleanup_warning(value_or_error, warning),
                committed and "uci_cleanup_warning" or nil
        end
        value_or_error = add_cleanup_warning(value_or_error, warning)
    end

    if not operation_ok then
        return false, value_or_error or (label .. " UCI transaction failed"),
            error_code or "uci_transaction_failed"
    end
    return true, value_or_error
end

return M
