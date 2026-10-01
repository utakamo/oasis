local M = {}

local marker = "oasis_tool_edge"
local registry_option = "oasis_rpc_account"
local lock_paths = {
    "/var/lock/oasis-tool-edge-account.lock",
    "/var/lock/oasis-settings.lock"
}

function M.username_valid(username)
    return type(username) == "string" and #username >= 1 and #username <= 64
        and username:match("^[-A-Za-z0-9_.]+$") ~= nil
        and username:match("^[A-Za-z0-9]") ~= nil
end

function M.release_lock(locks)
    for index = #(locks or {}), 1, -1 do
        locks[index]:close()
    end
end

function M.acquire_lock()
    local nixio = require("nixio")
    local locks = {}
    -- Account operations also serialize with General Settings UCI commits.
    for _, path in ipairs(lock_paths) do
        local lock = nixio.open(path, "a", "0600")
        if not lock then
            M.release_lock(locks)
            return nil
        end
        locks[#locks + 1] = lock
        if not lock:seek(0, "set") or not lock:lock("tlock") then
            M.release_lock(locks)
            return nil
        end
    end
    return locks
end

local function read_registry(uci)
    local config = uci:get_all("oasis")
    if type(config) ~= "table" then return nil, "read_failed" end
    local rpc = config.rpc
    if type(rpc) ~= "table" or rpc[".type"] ~= "rpc" then
        return nil, "invalid_registry"
    end
    local value = rpc[registry_option]
    if value ~= nil and value ~= "" and not M.username_valid(value) then
        return nil, "invalid_registry"
    end
    return { username = value or "", value = value }
end

local function inspect(uci)
    local registry, err = read_registry(uci)
    if not registry then return nil, err end
    local sections = uci:get_all("rpcd")
    if type(sections) ~= "table" then return nil, "read_failed" end
    local managed, usernames = {}, {}
    for name, section in pairs(sections) do
        if section[".type"] == "login" then
            local username = section.username
            if type(username) == "string" then
                usernames[username] = (usernames[username] or 0) + 1
            end
            if section[marker] == "1" then
                if not section[".name"] then return nil, "invalid_account" end
                managed[#managed + 1] = section
            end
        end
    end
    if #managed > 1 then return nil, "duplicate" end
    local account = managed[1]
    if account then
        if not M.username_valid(account.username) then return nil, "invalid_account" end
        if usernames[account.username] ~= 1 then return nil, "duplicate_username" end
        if registry.username ~= "" and registry.username ~= account.username then
            return nil, "registry_mismatch"
        end
    elseif registry.username ~= "" then
        return nil, "registry_mismatch"
    end
    registry.account = account
    return registry
end

function M.find(uci)
    local state, err = inspect(uci)
    if not state then return nil, err end
    if state.account and state.username == "" then
        return nil, "registry_missing"
    end
    return state.account, nil, state.username
end

local function set_registry(uci, value)
    local registry, err = read_registry(uci)
    if not registry then return false, err end
    if value == nil then
        return registry.value == nil or uci:delete("oasis", "rpc", registry_option)
    end
    return uci:set("oasis", "rpc", registry_option, value)
end

-- Migration is explicit at install/restore time. Removal never invents a
-- missing registry entry from the account it is about to delete.
function M.migrate(uci)
    local state, err = inspect(uci)
    if not state then return false, err end
    if not state.account or state.username ~= "" then return true end
    local ok, saved = pcall(function()
        return set_registry(uci, state.account.username) and uci:commit("oasis")
    end)
    if not ok or not saved then
        pcall(uci.revert, uci, "oasis")
        return false, "save_failed"
    end
    return true
end

local function restore_account(uci, previous, username)
    -- Anonymous UCI section names can change after a commit/reload. Resolve
    -- the unique marked login again rather than reusing a stale section name.
    local sections = uci:get_all("rpcd")
    if type(sections) ~= "table" then return false end
    local current
    for _, section in pairs(sections) do
        if section[".type"] == "login" and section[marker] == "1" then
            if not M.username_valid(section.username) or current or (section.username ~= username
                and not (previous and section.username == previous.username)) then
                return false
            end
            current = section
        end
    end
    if current and type(current[".name"]) ~= "string" then return false end
    if not previous then
        if current and not uci:delete("rpcd", current[".name"]) then
            return false
        end
    else
        local name = previous[".name"]
        if current then
            name = current[".name"]
            for option in pairs(current) do
                if option:sub(1, 1) ~= "." and not uci:delete("rpcd", name, option) then
                    return false
                end
            end
        elseif previous[".anonymous"] then
            name = uci:add("rpcd", "login")
            if type(name) ~= "string" then return false end
        else
            if sections[name] or not uci:set("rpcd", name, "login") then
                return false
            end
        end
        for option, value in pairs(previous) do
            if option:sub(1, 1) ~= "." then
                local ok
                if type(value) == "table" then
                    ok = uci:set_list("rpcd", name, option, value)
                else
                    ok = uci:set("rpcd", name, option, value)
                end
                if not ok then return false end
            end
        end
    end
    return uci:commit("rpcd")
end

-- The caller stages only the selected rpcd login while holding both locks.
-- UCI commits are per file; compensate a failed save without replacing
-- either full configuration or storing credentials in backup files.
function M.save(uci, previous, username)
    if username ~= nil and not M.username_valid(username) then
        pcall(uci.revert, uci, "rpcd")
        return false, "invalid_account"
    end
    local registry, err = read_registry(uci)
    if not registry then
        pcall(uci.revert, uci, "rpcd")
        return false, err
    end
    local rpcd_attempted = false
    local ok, saved = pcall(function()
        if not set_registry(uci, username) then return false end
        rpcd_attempted = true
        if not uci:commit("rpcd") then return false end
        return uci:commit("oasis")
    end)
    if ok and saved then return true end
    pcall(uci.revert, uci, "rpcd")
    pcall(uci.revert, uci, "oasis")
    if rpcd_attempted then
        local restored, restored_account = pcall(restore_account, uci, previous, username)
        local restored_registry, registry_saved = pcall(function()
            local current = read_registry(uci)
            if not current then return false end
            if current.value == registry.value then return true end
            return set_registry(uci, registry.value) and uci:commit("oasis")
        end)
        if not restored or not restored_account or not restored_registry or not registry_saved then
            pcall(uci.revert, uci, "rpcd")
            pcall(uci.revert, uci, "oasis")
            return false, "rollback_failed", true
        end
    end
    return false, "save_failed", rpcd_attempted
end

function M.remove(uci)
    local account, err = M.find(uci)
    if err then return false, err end
    if not account then return true, "no_account" end
    if not uci:delete("rpcd", account[".name"]) then
        pcall(uci.revert, uci, "rpcd")
        return false, "save_failed"
    end
    return M.save(uci, account, nil)
end

return M
