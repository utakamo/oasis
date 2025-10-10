#!/usr/bin/env lua

local util  = require("luci.util")
-- local debug = require("oasis.chat.debug")

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

local write_file = function(filename, data)
    local file = io.open(filename, "w")
    file:write(data)
    file:close()
end

local read_file = function(filename)
    local file = io.open(filename, "r")  -- open in read mode
    if not file then
        return nil, "Failed to open file"
    end

    local content = file:read("*a")  -- read the entire file
    file:close()  -- close the file
    return content
end

local function copy_file(src, dst)
    local rf, err1 = io.open(src, "rb")
    if not rf then return false, "Failed to open source: " .. (err1 or "") end

    local wf, err2 = io.open(dst, "wb")
    if not wf then rf:close(); return false, "Failed to open destination: " .. (err2 or "") end

    local chunk_size = 64 * 1024
    while true do
        local data = rf:read(chunk_size)
        if not data then break end
        local ok, write_err = wf:write(data)
        if not ok then
            rf:close(); wf:close()
            return false, "Write failed: " .. (write_err or "")
        end
    end

    rf:close(); wf:close()
    return true
end

-- Check whether /etc/init.d/<service> exists (with safe validation)
local check_init_script_exists = function(service)

	if type(service) ~= "string" then
		return false
	end

	local guard = require("oasis.security.guard")

	service = service:match("^%s*(.-)%s*$") or ""
	if #service == 0 then
		return false
	end

	if not guard.check_safe_string(service) then
		return false
	end

	service = guard.sanitize(service)

	local init_script = "/etc/init.d/" .. service
    -- debug:log("oasis.log", "check_init_script_exists", "service = " .. service)
	return check_file_exist(init_script)
end

return {
    markdown = markdown,
    get_uptime = get_uptime,
    normalize_path = normalize_path,
    check_file_exist = check_file_exist,
    touch = touch,
    write_file = write_file,
    read_file = read_file,
    copy_file = copy_file,
    check_init_script_exists = check_init_script_exists,
}