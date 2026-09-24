-- Boot-scoped state only. Never restore this directory from persistent storage
-- or remove it on a service restart / tool registry refresh.
local nixio = require("nixio")
local fs = require("nixio.fs")
local jsonc = require("luci.jsonc")
local M = {}
local DIRECTORY = "/tmp/oasis-tool-auto"
local PATH = DIRECTORY .. "/state.json"
local MAX_BYTES = 4 * 1024 * 1024

local function private_path(path, kind, missing_ok)
    local stat, code = fs.lstat(path)
    if not stat then
        return missing_ok and code == 2
    end
    return stat.type == kind and stat.uid == 0
        and stat.modestr == (kind == "dir" and "rwx------" or "rw-------")
        and (kind == "dir" or stat.nlink == 1)
end

local function directory(create)
    local stat, code = fs.lstat(DIRECTORY)
    if not stat and code == 2 then
        if not create then return true end
        -- A concurrent creator is harmless; validate the resulting directory.
        fs.mkdir(DIRECTORY, "0700")
    end
    return private_path(DIRECTORY, "dir", false)
end

function M.read()
    if not directory(false) or not private_path(PATH, "reg", true) then
        return nil, "Unsafe Auto tool state path or permissions."
    end
    local stat, code = fs.lstat(PATH)
    if not stat and code == 2 then
        return { version = 1, enabled = {} }
    end
    local raw = fs.readfile(PATH, MAX_BYTES + 1)
    if type(raw) ~= "string" or #raw > MAX_BYTES then
        return nil, "Failed to read Auto tool state."
    end
    local ok, value = pcall(jsonc.parse, raw)
    if not ok or type(value) ~= "table" or value.version ~= 1
        or type(value.enabled) ~= "table" then
        return nil, "Invalid Auto tool state."
    end
    for key, fingerprint in pairs(value.enabled) do
        if type(key) ~= "string" or type(fingerprint) ~= "string" then
            return nil, "Invalid Auto tool state entry."
        end
    end
    return value
end

-- The same lock serializes volatile mutations and persistent mode changes.
-- Readers see either complete file through atomic rename; no partial JSON.
function M.with_lock(callback)
    if not directory(true)
        or not private_path(DIRECTORY .. "/lock", "reg", true) then
        return nil, "Unsafe Auto tool lock path or permissions."
    end
    local lock = nixio.open(DIRECTORY .. "/lock", "a", "0600")
    if not lock then return nil, "Failed to open Auto tool lock." end
    if not lock:lock("tlock") then
        lock:close()
        return nil, "Another Auto tool update is in progress."
    end
    local ok, result, err = pcall(callback)
    lock:lock("ulock")
    lock:close()
    if not ok then return nil, "Auto tool update failed." end
    return result, err
end

-- Called only while holding with_lock(). Exclusive creation and the private
-- directory prevent following a pre-existing temporary-file symlink.
function M.write(value)
    local raw = jsonc.stringify(value)
    if type(raw) ~= "string" or #raw > MAX_BYTES then
        return nil, "Auto tool state is too large."
    end
    local temporary = PATH .. ".new"
    if not private_path(temporary, "reg", true) then
        return nil, "Unsafe Auto tool temporary file."
    end
    -- Recover a file left by an interrupted previous writer under this lock.
    if fs.lstat(temporary) and not fs.unlink(temporary) then
        return nil, "Failed to remove stale Auto tool temporary file."
    end
    local file = nixio.open(temporary,
        nixio.open_flags("wronly", "creat", "excl"), "0600")
    if not file then return nil, "Failed to create Auto tool state." end
    local written = file:writeall(raw)
    local closed = file:close()
    if written ~= #raw or not closed or not fs.rename(temporary, PATH) then
        fs.unlink(temporary)
        return nil, "Failed to save Auto tool state."
    end
    return true
end

return M
