#!/usr/bin/env lua

local util  = require("luci.util")

local schedule_reboot = function(delay_seconds)
    delay_seconds = tonumber(delay_seconds) or 0
    if delay_seconds < 0 then delay_seconds = 0 end

    util.exec("(sleep " .. tostring(delay_seconds) .. " && reboot) >/dev/null 2>&1 &")
end

local system_reboot_after_5sec  = function() schedule_reboot(5)  end
local system_reboot_after_10sec = function() schedule_reboot(10) end
local system_reboot_after_15sec = function() schedule_reboot(15) end
local system_reboot_after_20sec = function() schedule_reboot(20) end

local system_command = function(cmd)

    local guard = require("oasis.security.guard")

    if not guard.check_safe_string(cmd) then
        return false
    end

    cmd = guard.sanitize(cmd)

    local command = cmd .. " >/dev/null 2>&1; echo $?"

    local out = util.exec(cmd)
    out = out:gsub("%s+$", "")
    local rc = tonumber(out)
    return (rc == 0)
end

local check_pkg_reboot_required = function(pkg)
    local misc = require("oasis.chat.misc")
    local common = require("oasis.common")
    return misc.check_file_exist(common.file.pkg.reboot_required_path  .. pkg)
end

return {
    system_reboot_after_5sec  = system_reboot_after_5sec,
    system_reboot_after_10sec = system_reboot_after_10sec,
    system_reboot_after_15sec = system_reboot_after_15sec,
    system_reboot_after_20sec = system_reboot_after_20sec,
    system_command = system_command,
    check_pkg_reboot_required = check_pkg_reboot_required,
}



