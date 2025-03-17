#!/usr/bin/env lua

local util = require("luci.util")
local uci = require("luci.model.uci").cursor()
local sys = require("luci.sys")

local status = {
    ok = "OK",
    error = "ERROR",
    not_found = "NOT FOUND",
}

local get_oasis_conf = function()
    local conf = {}
    conf.path = uci:get("oasis", "storage", "path")
    conf.prefix = uci:get("oasis", "storage", "prefix")
    conf.model = uci:get_first("oasis", "service", "model")
    conf.url = uci:get_first("oasis", "service", "url", "")
    conf.api_key = uci:get_first("oasis", "service", "api_key", "")
    return conf
end

local get_target_id_section = function(id)

    local unnamed_section = ""

    uci:foreach("oasis", "chat", function(info)
        if id == info.id then
            unnamed_section = info[".name"]
        end
    end)

    return unnamed_section
end

local normalize_path = function(path)
    if string.sub(path, -1) ~= "/" then
        path = path .. "/"
    end
    return path
end

local search_chat_id = function(id)

    local is_search = false

    uci:foreach("oasis", "chat", function(info)
        if id == info.id then
            is_search = true
        end
    end)

    return is_search
end

local load_conf_file = function(filename)
    local iniFile = io.open(filename, "r")
    if not iniFile then return nil, "Cannot open file: " .. filename end

    local data = {}
    local currentSection = nil
    local currentKey = nil
    local isMultilineValue = false
    local multilineBuffer = ""

    for line in iniFile:lines() do
        local trimmedLine = line:match("^%s*(.-)%s*$")
        if trimmedLine ~= "" and not trimmedLine:match("^;") and not trimmedLine:match("^#") then
            local section = trimmedLine:match("^%[(.-)%]$")
            if section then
                currentSection = section
                data[currentSection] = {}
            elseif isMultilineValue then
                if trimmedLine:match('".-$') then
                    multilineBuffer = multilineBuffer .. "\n" .. trimmedLine:match("^(.-)\"$")
                    data[currentSection][currentKey] = multilineBuffer
                    isMultilineValue = false
                    multilineBuffer = ""
                    currentKey = nil
                else
                    multilineBuffer = multilineBuffer .. "\n" .. trimmedLine
                end
            else
                local key, value = trimmedLine:match("^(.-)%s*=%s*(.-)$")
                if key and value and currentSection then
                    if value:match("^\".*\"$") then
                        data[currentSection][key] = value:match("^\"(.-)\"$")
                    elseif value:match("^\".*$") then
                        isMultilineValue = true
                        currentKey = key
                        multilineBuffer = value:match("^\"(.-)$")
                    else
                        data[currentSection][key] = value
                    end
                end
            end
        end
    end

    iniFile:close()
    return data
end

local update_conf_file = function(filename, data)
    local iniFile = io.open(filename, "w")
    if not iniFile then return nil, "Cannot open file: " .. filename end

    for section, sectionData in pairs(data) do
        iniFile:write("[" .. section .. "]\n")
        for key, value in pairs(sectionData) do
            iniFile:write(key .. " = \"" .. value .. "\"\n")
        end
        iniFile:write("\n")
    end

    iniFile:close()
    return true
end

local get_uptime = function()
    local system_info = util.ubus("system", "info", {})
    return system_info.uptime
end

local check_file_exist = function(file)
    local f = io.open(file, "r")
    if f then
        f:close()
        return true
    else
        return false
    end
end

local file_exist = function(file_name)
    local f = io.open(file_name, "r")
    if f then f:close() end
    return f ~= nil
end

local touch = function(filename)

    local result = false

    if not file_exist(filename) then
        local file = io.open(filename, "w")
        if file then
            file:close()
            result = true
        end
    end

    return result
end

local generate_chat_id = function()

    local id
    local retry = 5

    local is_exist

    -- debug_log("generate_chat_id")

    repeat
        retry = retry - 1

        id = sys.exec("tr -dc '0-9' < /dev/urandom | head -c 10 > /tmp/random_number && cat /tmp/random_number")

        -- debug_log(id)

        is_exist = search_chat_id(id)

    until (not is_exist) or (retry <= 0)

    if is_exist then
        id = ""
    end

    -- debug_log("new = " .. id)

    return id
end

local check_chat_format = function(chat)

    if type(chat) ~= "table" then
        return false
    end

    if type(chat.messages) ~= "table" then
        return false
    end

    for _, msg in ipairs(chat.messages) do
        if type(msg) ~= "table" then
            return false
        end

        if type(msg.content) ~= "string" or type(msg.role) ~= "string" then
            return false
        end
    end

    return true
end

return {
    status = status,
    get_oasis_conf = get_oasis_conf,
    get_target_id_section = get_target_id_section,
    normalize_path = normalize_path,
    search_chat_id = search_chat_id,
    load_conf_file = load_conf_file,
    update_conf_file = update_conf_file,
    get_uptime = get_uptime,
    check_file_exist = check_file_exist,
    file_exist = file_exist,
    touch = touch,
    generate_chat_id = generate_chat_id,
    check_chat_format = check_chat_format,
}