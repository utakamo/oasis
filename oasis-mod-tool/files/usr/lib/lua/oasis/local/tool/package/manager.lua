#!/usr/bin/env lua

local util  = require("luci.util")

local target_pkg_manager = "ipk"

local check_installed_pkg(pkg)

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

local update_pkg_info = function(pkg_manager)
    
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

-- Add check to install_pkg as well
local install_pkg = function(pkg)

    local guard = require("oasis.security.guard")

    -- Validate package name and reject if invalid
    if not guard.check_safe_string(pkg) then
        return false
    end

    -- Shell-escape the package name (defensive; whitelist already restricts allowed chars)
    local quoted_pkg = "'" .. tostring(pkg):gsub("'", "'\\''") .. "'"

    if target_pkg_manager == "ipk" then
        local out = util.exec("opkg install " .. quoted_pkg .. " >/dev/null 2>&1; echo $?")
        out = out:gsub("%s+$", "")
        local rc = tonumber(out)
        return (rc == 0)
    elseif target_pkg_manager == "apk" then
        local out = util.exec("apk add " .. quoted_pkg .. " >/dev/null 2>&1; echo $?") or ""
        out = out:gsub("%s+$", "")
        local rc = tonumber(out)
        return (rc == 0)
    end

    return false
end

return {
    check_installed_pkg = check_installed_pkg,
    update_pkg_info = update_pkg_info,
    install_pkg = install_pkg,
}