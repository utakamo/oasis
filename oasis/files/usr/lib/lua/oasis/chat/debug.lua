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

    --- Write a log line.
    -- @param filename string output file name
    -- @param ... any message parts
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
            local vt = type(v)
            if vt == "string" or vt == "number" or vt == "boolean" or vt == "nil" then
                self:log(filename, key_path .. "=" .. tostring(v))
            elseif vt == "table" then
                self:recursive_dump(filename, v, key_path)
            else
                self:log(filename, key_path .. "=<" .. vt .. ">")
            end
        end
    end

    --- Dump a table recursively.
    -- @param filename string
    -- @param data table|any
    obj.dump = function(self, filename, data)
        if self.disabled then return end
        if type(data) ~= "table" then
            self:log(filename, tostring(data))
            return
        end
        self:recursive_dump(filename, data, "data")
    end

    --- Convenience: info level log (alias to log)
    -- @param filename string
    -- @param msg string
    obj.info = function(self, filename, msg)
        self:log(filename, msg)
    end

    --- Convenience: warn level log (alias to log with prefix)
    -- @param filename string
    -- @param msg string
    obj.warn = function(self, filename, msg)
        self:log(filename, "WARN", msg)
    end

    --- Convenience: error level log (alias to log with prefix)
    -- @param filename string
    -- @param msg string
    obj.error = function(self, filename, msg)
        self:log(filename, "ERROR", msg)
    end

    return obj
end

return debug.new()