#!/usr/bin/env lua

local util  = require("luci.util")
local misc  = require("oasis.chat.misc")
local common = require("oasis.common")
local debug = require("oasis.chat.debug")

local M = {}

local target_pkg_manager = "ipk"

function M.check_installed_pkg(pkg)

    local guard = require("oasis.security.guard")

    -- Validate package name and reject if invalid
    if not guard.check_safe_string(pkg) then
        return false
    end

    pkg = guard.sanitize(pkg)

    if target_pkg_manager == "ipk" then
        local out = util.exec("opkg list-installed | grep " .. pkg .." >/dev/null 2>&1; echo $?")
        out = out:gsub("%s+$", "")
        local rc = tonumber(out)
        return (rc == 0)
    elseif target_pkg_manager == "apk" then
        local out = util.exec("apk info -vv | grep " .. pkg .. " >/dev/null 2>&1; echo $?")
        out = out:gsub("%s+$", "")
        local rc = tonumber(out)
        return (rc == 0)
    end

    return false
end

function M.update_pkg_info(pkg_manager)

    target_pkg_manager = pkg_manager
    local result = false

    if target_pkg_manager == "ipk" then
        local out = util.exec("opkg update >/dev/null 2>&1; echo $?")
        out = out:gsub("%s+$", "")
        local rc = tonumber(out)
        return (rc == 0)
    elseif target_pkg_manager == "apk" then
        local out = util.exec("apk update >/dev/null 2>&1; echo $?") or ""
        out = out:gsub("%s+$", "")
        local rc = tonumber(out)
        return (rc == 0)
    end

    return result
end

function M.check_process_alive(pid)
    local ok = os.execute("kill -0 " .. tonumber(pid) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
end

local start_install_pkg = function(pkg)
    local guard = require("oasis.security.guard")

    if not guard.check_safe_string(pkg) then
        return 0
    end

    local cmd
    if target_pkg_manager == "ipk" then
        cmd = "/bin/opkg"
    elseif target_pkg_manager == "apk" then
        cmd = "/bin/apk"
    else
        return 0
    end

    local pipe = io.popen(string.format("%s install %s >/dev/null 2>&1 & echo $!", cmd, pkg))
    local pid = tonumber(pipe:read("*l"))
    pipe:close()

    if not pid then
        debug:log("oasis.log", "install_pkg", "pid failed")
        return 0
    end

    return pid
end

function M.install_pkg(pkg)
    local pid = start_install_pkg(pkg)

    if type(pid) ~= "number" then
        return false
    end

    if pid == 0 then
        return false
    end

    misc.write_file(common.file.pkg.install, pkg .. "|" .. pid)

    return true
end

function M.check_pkg_reboot_required(pkg)
    return misc.check_file_exist(common.file.pkg.reboot_required_path  .. pkg)
end

return M
