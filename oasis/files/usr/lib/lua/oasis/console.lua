#!/usr/bin/env lua

local common = require("oasis.common")

local M = {}

-- Thin console wrapper to centralize IO and colors

function M.write(s)
    io.write(s or "")
end

function M.flush()
    io.flush()
end

function M.read()
    return io.read()
end

function M.print(s)
    print(s or "")
end

function M.printf(fmt, ...)
    io.write(string.format(fmt, ...))
    io.flush()
end

function M.colorize(color, text)
    local c = common.console and common.console.color or {}
    local reset = c.RESET or "\27[0m"
    local code = c[color] or ""
    if #code > 0 then
        return code .. (text or "") .. reset
    end
    return text or ""
end

return M


