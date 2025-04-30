#!/usr/bin/env lua

local util  = require("luci.util")

local markdown = function(mark, message)

    if not mark then
        message = message:gsub("```", "\27[1;32;47m")
        message = message:gsub("\27%[1;32;47m(.-)\27%[1;32;47m", "\27[1;32;47m%1\27[0m")
        message = message:gsub("%*%*", "\27[1;33m")
        message = message:gsub("\27%[1;33m(.-)\27%[1;33m", "\27[1;33m%1\27[0m")
    else
        if not mark.cnt then
            mark.cnt = {}
            mark.cnt.code_block = 0
            mark.cnt.bold_text = 0
        end

        while true do
            local is_code_block = (message:match("```") ~= nil)

            if not is_code_block then
                break
            end

            mark.cnt.code_block = mark.cnt.code_block + 1

            -- replace code blocks
            if (mark.cnt.code_block % 2) == 1 then
                message = message:gsub("```", "\27[1;32;47m", 1)
            else
                message = message:gsub("```", "\27[0m", 1)
            end
        end

        while true do
            local is_bold_text = (message:match("%*%*") ~= nil)

            if not is_bold_text then
                break
            end

            mark.cnt.bold_text = mark.cnt.bold_text + 1

            -- replace bold blocks
            if (mark.cnt.bold_text % 2) == 1 then
                message = message:gsub("%*%*", "\27[1;33m")
            else
                message = message:gsub("%*%*", "\27[0m")
            end
        end
    end

    return message
end

local get_uptime = function()
    local system_info = util.ubus("system", "info", {})
    return system_info.uptime
end

local normalize_path = function(path)
    if string.sub(path, -1) ~= "/" then
        path = path .. "/"
    end
    return path
end

local check_file_exist = function(filename)
    local f = io.open(filename, "r")

    if f then
        f:close()
        return true
    end

    return false
end

local touch = function(filename)

    if not check_file_exist(filename) then
        local file = io.open(filename, "w")
        if file then
            file:close()
            return true
        end
    end

    return false
end

return {
    markdown = markdown,
    get_uptime = get_uptime,
    normalize_path = normalize_path,
    check_file_exist = check_file_exist,
    touch = touch,
}