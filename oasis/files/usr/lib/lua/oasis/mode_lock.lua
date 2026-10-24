local nixio = require("nixio")
local fs = require("nixio.fs")
local M = {}
-- Retain the existing lock inode across upgrades and Agent removal.
local DIRECTORY = "/tmp/oasis-tool-auto"
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


return M
