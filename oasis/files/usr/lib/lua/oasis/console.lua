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

-- os.execute inherits both descriptors; io.popen would turn stdout into a pipe.
function M.is_interactive()
    local ok = os.execute("test -t 0 && test -t 1")
    return ok == true or ok == 0
end

local form_colors = {
    heading = "\27[1;36m", label = "\27[1m", hint = "\27[2m",
    success = "\27[32m", warning = "\27[33m", error = "\27[31m",
}
local color_tty

function M.form_style(style, text)
    local no_color, term = os.getenv("NO_COLOR"), os.getenv("TERM")
    if (no_color and no_color ~= "") or not term or term == "" or term == "dumb" then
        return text
    end
    if color_tty == nil then
        local ok = os.execute("test -t 1")
        color_tty = ok == true or ok == 0
    end
    local color = color_tty and form_colors[style]
    return color and (color .. text .. "\27[0m") or text
end

function M.read_secret()
    local pipe = io.popen("/usr/libexec/oasis-read-secret", "r")
    if not pipe then return nil, "input_failed" end
    local ok, line = pcall(pipe.read, pipe, "*l")
    pipe:close()
    M.print()
    if not ok or type(line) ~= "string" or line:sub(1, 3) ~= "ok:" then
        return nil, "cancelled"
    end
    return line:sub(4)
end

function M.read_form_line()
    local chunks, size, overflow = {}, 0, false
    while true do
        local char = io.read(1)
        if char == nil then return nil, "cancelled" end
        if char == "\n" then break end
        size = size + 1
        if size <= 4096 then chunks[#chunks + 1] = char else overflow = true end
    end
    if overflow then return nil, "input_too_long" end
    return table.concat(chunks)
end

return M


