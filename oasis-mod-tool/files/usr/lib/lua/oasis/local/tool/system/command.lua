#!/usr/bin/env lua

local util  = require("luci.util")

local schedule_reboot = function(delay_seconds)
    delay_seconds = tonumber(delay_seconds) or 0
    if delay_seconds < 0 then delay_seconds = 0 end

    -- Use sh -c to ensure the sleep+reboot runs in a subshell and is backgrounded.
    util.exec("sh -c 'sleep " .. tostring(delay_seconds) .. " && reboot' >/dev/null 2>&1 &")
end

local system_reboot_after_5sec  = function() schedule_reboot(5)  end
local system_reboot_after_10sec = function() schedule_reboot(10) end
local system_reboot_after_15sec = function() schedule_reboot(15) end
local system_reboot_after_20sec = function() schedule_reboot(20) end

function sanitize(str)
  return str:gsub("[;&|><`]", "")
end

function is_safe_input(str)
  return str:match("^[%w%-_%.]+$") ~= nil
end

local system_command = function(cmd)

    if not is_safe_input(cmd) then
        return false
    end

    sanitize(str)

    local command = cmd .. " >/dev/null 2>&1; echo $?"

    local out = util.exec(cmd)
    out = out:gsub("%s+$", "")
    local rc = tonumber(out)
    return (rc == 0)
end

return {
    schedule_reboot = schedule_reboot,
    system_reboot_after_5sec  = system_reboot_after_5sec,
    system_reboot_after_10sec = system_reboot_after_10sec,
    system_reboot_after_15sec = system_reboot_after_15sec,
    system_reboot_after_20sec = system_reboot_after_20sec,
    system_command = system_command,
}



