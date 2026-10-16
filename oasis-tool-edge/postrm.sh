#!/bin/sh

[ -n "${IPKG_INSTROOT}" ] && exit 0
[ "$1" = upgrade ] && exit 0
[ "${PKG_UPGRADE}" = 1 ] && exit 0

# This script is embedded in package metadata: package-owned files are already
# gone when a removal hook runs. The Lua runtime belongs to our dependencies.
lua - <<'LUA'
local nixio = require("nixio")
local fs = require("nixio.fs")
local marker_root = "/tmp/oasis-tool-edge-upgrade"

local function warn(message)
    io.stderr:write("oasis-tool-edge: " .. message .. "\n")
end

local function read_file(path)
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

local function private_path(path, kind, mode)
    local stat = fs.lstat(path)
    return stat and stat.type == kind and stat.uid == 0 and stat.modedec == mode
end

local function process_identity(pid)
    local content = read_file("/proc/" .. pid .. "/stat")
    local fields = content and content:match("^%d+ %(.+%) (.*)")
    if not fields then
        return nil
    end
    local values = {}
    for value in fields:gmatch("%S+") do
        values[#values + 1] = value
    end
    return tonumber(values[2]), values[20]
end

local function local_upgrade()
    if not private_path(marker_root, "dir", 700) then
        return false
    end
    local pid = nixio.getpid()
    -- Match only an ancestor of this hook, including its kernel start time.
    -- A stale marker, PID reuse, or an unrelated removal cannot preserve it.
    for _ = 1, 64 do
        if not pid or pid <= 1 then
            break
        end
        local parent, start_time = process_identity(pid)
        if not start_time or not start_time:match("^%d+$") then
            break
        end
        local marker = marker_root .. "/" .. pid .. "-" .. start_time
        if private_path(marker, "reg", 600)
            and read_file(marker) == pid .. " " .. start_time .. " oasis-tool-edge\n" then
            return true
        end
        pid = parent
    end
    return false
end

if local_upgrade() then
    os.exit(0)
end

local failed = false
local function fail(message)
    failed = true
    warn(message)
end

local locks
local loaded, uci = pcall(function()
    return require("luci.model.uci").cursor()
end)
if not loaded then
    fail("Could not load UCI support; its credentials were retained.")
else
    local ok = pcall(function()
        local account = require("oasis.tool_edge.account")
        locks = account.acquire_lock()
        if not locks then
            fail("Could not lock the managed account; its credentials were retained.")
            return
        end
        local removed, reason = account.remove(uci)
        if not removed then
            fail("Managed account cleanup failed (" .. reason .. "); review rpcd and Oasis registry settings.")
        elseif reason == "no_account" then
            warn("No managed login found; no rpcd login was deleted.")
        end
    end)
    if not ok then
        pcall(uci.revert, uci, "rpcd")
        pcall(uci.revert, uci, "oasis")
        fail("Managed login cleanup failed; check rpcd configuration.")
    end
    ok = pcall(function()
        if fs.access("/etc/config/oasis") then
            -- A failed account lock must not commit another settings request's
            -- staged registry update. Take the settings lock separately.
            if not locks then
                local lock = nixio.open("/var/lock/oasis-settings.lock", "a", "0600")
                if not (lock and lock:seek(0, "set") and lock:lock("tlock")) then
                    if lock then lock:close() end
                    fail("Could not lock Oasis settings; its support flag was retained.")
                    return
                end
                locks = {lock}
            end
            if not uci:set("oasis", "support", "tool_edge", "0") then
                fail("Could not disable Tool Edge support.")
            elseif not uci:commit("oasis") then
                uci:revert("oasis")
                fail("Could not save the disabled Tool Edge support setting.")
            end
        end
    end)
    if not ok then
        pcall(uci.revert, uci, "oasis")
        fail("Could not disable Tool Edge support.")
    end
end
for index = #(locks or {}), 1, -1 do
    locks[index]:close()
end

-- Also invalidate loaded objects/ACLs when an absent or ambiguous account
-- cannot be deleted. Restarting rpcd may end active LuCI sessions.
local restarted = fs.access("/etc/init.d/rpcd", "x")
    and os.execute("/etc/init.d/rpcd restart >/dev/null 2>&1")
if restarted ~= 0 and restarted ~= true then
    fail("Could not restart rpcd; loaded sessions and ACLs may remain active.")
end
os.exit(failed and 1 or 0)
LUA
