#!/usr/bin/env lua

local sys       = require("luci.sys")

local log = function(filename, msg)
    sys.exec("echo \"" .. msg .. "\" >> /tmp/" .. filename)
end

local dump = function(filename, data)
    -- debug
    for k1, v1 in pairs(data) do
        if type(v1) == "string" then
            log(filename, "data[" .. k1 .. "]=" .. v1)
        elseif type(v1) == "table" then
            for k2, v2 in pairs(v1) do
                if type(v2) == "string" then
                    log(filename, "data[" .. k1 .. "][" .. k2 .. "]=" .. v2)
                elseif type(v2) == "table" then
                    for k3, v3 in pairs(v2) do
                        if type(v3) == "string" then
                            log(filename, "data[" .. k1 .. "][" .. k2 .. "][" .. k3 .. "]=" .. v3)
                        end
                    end
                end
            end
        end
    end
end

return {
    log = log,
    dump = dump,
}