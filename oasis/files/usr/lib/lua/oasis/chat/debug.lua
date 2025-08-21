#!/usr/bin/env lua

--[[
[Debug Log Mode]
Debug log can be enabled by executing the following UCI commands:
- uci set oasis.debug.disabled=0
- uci commit oasis

Additionally, to set the log output destination to a static area (/etc/oasis), use the following command:
- uci set oasis.debug.volatile=0
- uci commit oasis

If volatile=1 (default), logs will be output to /tmp.

Note:
Currently, when debug logs are enabled, only the processing of Oasis UBUS objects is logged.
To enable logging for the Lua script being debugged, add calls to the log or dump functions.
]]

local uci = require("luci.model.uci").cursor()

local debug = {}
debug.new = function()

    local obj = {}

    obj.disabled = uci:get_bool("oasis", "debug", "disabled")

    obj.dest = "/etc/oasis/"

    if uci:get_bool("oasis", "debug", "volatile") then
        obj.dest = "/tmp/"
    end

    obj.log = function(self, filename, ...)
        if self.disabled then return end

        local args = {...}
        local msg = ""

        if #args == 1 then
            msg = tostring(args[1])
        elseif #args >= 2 then
            -- second arg is caller function name, third is the message
            msg = "[" .. tostring(args[1]) .. "] " .. tostring(args[2])
        else
            msg = ""
        end

        local path = self.dest .. filename
        local file = io.open(path, "a")
        if not file then
            return
        end
        file:write(msg .. "\n")
        file:close()
    end

    obj.recursive_dump = function(self, filename, tbl, path)
        for k, v in pairs(tbl) do
            local key_path = path .. "[" .. tostring(k) .. "]"
            if type(v) == "string" then
                self:log(filename, key_path .. "=" .. v)
            elseif type(v) == "table" then
                self:recursive_dump(filename, v, key_path)
            end
        end
    end

    obj.dump = function(self, filename, data)
        if self.disabled then return end
        self:recursive_dump(filename, data, "data")
    end

    return obj
end

return debug.new()