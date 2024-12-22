#!/usr/bin/env lua

local uci = require("luci.model.uci").cursor()

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
        -- debug_log("file: " .. info.id)
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

    for line in iniFile:lines() do
        local trimmedLine = line:match("^%s*(.-)%s*$")
        if trimmedLine ~= "" and not trimmedLine:match("^;") and not trimmedLine:match("^#") then
            local section = trimmedLine:match("^%[(.-)%]$")
            if section then
                currentSection = section
                data[currentSection] = {}
            else
                local key, value = trimmedLine:match("^(.-)%s*=%s*(.-)$")
                if key and value and currentSection then
                    data[currentSection][key] = value
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
            iniFile:write(key .. " = " .. value .. "\n")
        end
        iniFile:write("\n")
    end

    iniFile:close()
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
}