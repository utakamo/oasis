#!/usr/bin/env lua

local util  = require("luci.util")
local uci   = require("luci.model.uci").cursor()
local sys   = require("luci.sys")

local db                     = {}
db.uci                       = {}
db.uci.cfg                   = "oasis"
db.uci.sect                  = {}
db.uci.sect.chat             = "chat"
db.uci.sect.storage          = "storage"
db.uci.sect.service          = "service"
db.uci.sect.backup           = "backup"
db.uci.sect.role             = "role"
db.uci.sect.assist           = "assist"

db.ubus                          = {}
db.ubus.object                   = {}
db.ubus.method                   = {}
db.ubus.object.system            = "system"
db.ubus.method.info              = "info"
db.ubus.object.oasis             = "oasis"
db.ubus.method.load_icon_info    = "load_icon_info"
db.ubus.method.select_icon       = "select_icon"
db.ubus.method.update_sysmsg     = "update_sysmsg"
db.ubus.method.load_sysmsg       = "load_sysmsg"
db.ubus.method.delete_icon       = "delete_icon"
db.ubus.method.confirm           = "confirm"
db.ubus.method.config            = "config"
db.ubus.method.load_sysmsg_info  = "load_sysmsg_info"
db.ubus.method.add_sysmsg        = "add_sysmsg"
db.ubus.method.delete_sysmsg     = "delete_sysmsg"
db.ubus.object.oasis_chat        = "oasis.chat"
db.ubus.method.delete            = "delete"
db.ubus.method.list              = "list"
db.ubus.method.append            = "append"
db.ubus.method.load              = "load"
db.ubus.method.create            = "create"
db.ubus.object.oasis_title       = "oasis.title"
db.ubus.method.auto_set          = "auto_set"
db.ubus.method.manual_set        = "manual_set"

local ai                            = {}
ai.service                          = {}
ai.service.ollama                   = {}
ai.service.ollama.name              = "Ollama"
ai.service.ollama.endpoint          = "http://[ollama ip address]:11434/api/chat"
ai.service.openai                   = {}
ai.service.openai.name              = "OpenAI"
ai.service.openai.endpoint          = "https://api.openai.com/v1/chat/completions"
ai.service.anthropic                = {}
ai.service.anthropic.name           = "Anthropic"
ai.service.anthropic.endpoint       = "https://api.anthropic.com/v1/messages"
ai.service.gemini                   = {}
ai.service.gemini.name              = "Gemini"
ai.service.gemini.endpoint          = "https://generativelanguage.googleapis.com"
ai.format                           = {}
ai.format.chat                      = "chat"
ai.format.prompt                    = "prompt"
ai.format.call                      = "call"
ai.format.output                    = "output"

local role = {}
role.system      = "system"
role.user        = "user"
role.assistant   = "assistant"
role.unknown     = "unknown"

local status        = {}
status.ok           = "OK"
status.error        = "ERROR"
status.not_found    = "NOT FOUND"

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

local get_oasis_conf = function()
    local cfg = {}
    cfg.path = uci:get(db.uci.cfg, db.uci.sect.storage, "path")
    cfg.prefix = uci:get(db.uci.cfg, db.uci.sect.storage, "prefix")
    cfg.model = uci:get_first(db.uci.cfg, db.uci.sect.service, "model")
    cfg.service = uci:get_first(db.uci.cfg, db.uci.sect.service, "name", "")
    cfg.api_key = uci:get_first(db.uci.cfg, db.uci.sect.service, "api_key", "")
    cfg.ipaddr = uci:get_first(db.uci.cfg, db.uci.sect.service, "ipaddr", "") or ""

    for _, service in pairs(ai.service) do
        if cfg.service == service.name then
            if cfg.service == ai.service.ollama.name then
                cfg.endpoint = string.gsub(ai.service.ollama.endpoint, "%[x%.x%.x%.x%]", cfg.ipaddr)
                break
            elseif cfg.service == ai.service.openai.name then
                cfg.endpoint = ai.service.openai.endpoint
                break
            elseif cfg.service == ai.service.anthropic.name then
                cfg.endpoint = ai.service.anthropic.endpoint
                break;
            elseif cfg.service == ai.service.gemini.name then
                cfg.endpoint = ai.service.gemini.endpoint
                break;
            elseif (cfg.service == ai.service.custom_ollama.name)
                    or (cfg.service == ai.service.custom_openai.name)
                    or (cfg.service == ai.service.custom_anthropic.name)
                    or (cfg.service == ai.service.custom_gemini.name) then
                cfg.endpoint = uci:get_first(db.uci.cfg, db.uci.sect.service, "endpoint", "") or ""
                break;
            end
        end
    end

    return cfg
end

local get_target_id_section = function(id)

    local unnamed_section = ""

    uci:foreach(db.uci.cfg, db.uci.sect.chat, function(info)
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

    uci:foreach(db.uci.cfg, db.uci.sect.chat, function(info)
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
                if trimmedLine:match('".-$') and (not trimmedLine:match('\\"')) then
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
                        data[currentSection][key] = value:gsub("\\n", "\n")
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
            iniFile:write(key .. " = \"" .. value:gsub("\n", "\\n") .. "\"\n")
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
    db = db,
    ai = ai,
    role = role,
    markdown = markdown,
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