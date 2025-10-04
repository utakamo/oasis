#!/usr/bin/env lua

local util  = require("luci.util")
local guard = require("oasis.security.guard")
local misc  = require("oasis.chat.misc")

local schedule_reboot = function(delay_seconds)
    delay_seconds = tonumber(delay_seconds) or 0
    if delay_seconds < 0 then delay_seconds = 0 end

    util.exec("(sleep " .. tostring(delay_seconds) .. " && reboot) >/dev/null 2>&1 &")
end

local check_service = function(service)

	if type(service) ~= "string" then
		return false
	end

	service = service:match("^%s*(.-)%s*$") or ""
	if #service == 0 then
		return false
	end

	if not misc.check_init_script_exists(service) then
		return false
	end

	if not guard.check_safe_string(service) then
		return false
	end

	return true
end

local schedule_restart = function(delay_seconds, service)

    if not check_service(service) then
        return
    end

    service = guard.sanitize(service)

    delay_seconds = tonumber(delay_seconds) or 0
    if delay_seconds < 0 then delay_seconds = 0 end

    local cmd
    if delay_seconds == 0 then
        cmd = "(/etc/init.d/" .. service .. " restart) >/dev/null 2>&1 &"
    else
        cmd = "(sleep " .. tostring(delay_seconds) .. " && /etc/init.d/" .. service .. " restart) >/dev/null 2>&1 &"
    end

    util.exec(cmd)
end

-- System Reboot
local system_reboot = function() schedule_reboot(0) end
local system_reboot_after_5sec  = function() schedule_reboot(5)  end
local system_reboot_after_10sec = function() schedule_reboot(10) end
local system_reboot_after_15sec = function() schedule_reboot(15) end
local system_reboot_after_20sec = function() schedule_reboot(20) end

-- Restart Service
local restart_service = function(service) schedule_restart(0, service) end
local restart_service_after_3sec = function(service) schedule_restart(3, service) end

local system_command = function(cmd)

    if not guard.check_safe_string(cmd) then
        return false
    end

    cmd = guard.sanitize(cmd)

    local command = cmd .. " >/dev/null 2>&1; echo $?"

    local out = util.exec(command)
    out = out:gsub("%s+$", "")
    local rc = tonumber(out)
    return (rc == 0)
end

return {
    system_reboot = system_reboot,
    system_reboot_after_5sec  = system_reboot_after_5sec,
    system_reboot_after_10sec = system_reboot_after_10sec,
    system_reboot_after_15sec = system_reboot_after_15sec,
    system_reboot_after_20sec = system_reboot_after_20sec,
	restart_service = restart_service,
	restart_service_after_3sec = restart_service_after_3sec,
	system_command = system_command,
}