#!/usr/bin/env lua

local ubus  = require("ubus")
local uci   = require("luci.model.uci").cursor()
local sys   = require("luci.sys")
local misc  = require("oasis.chat.misc")
-- local debug = require("oasis.chat.debug")

local db                     = {}
db.uci                       = {}
db.uci.cfg                   = "oasis"
db.uci.sect                  = {}
db.uci.sect.chat             = "chat"
db.uci.sect.storage          = "storage"
db.uci.sect.service          = "service"
db.uci.sect.rollback         = "rollback"
db.uci.sect.role             = "role"
db.uci.sect.assist           = "assist"
db.uci.sect.rpc              = "rpc"
db.uci.sect.support          = "support"
db.uci.sect.tool             = "tool"
db.uci.sect.remote_mcp       = "remote_mcp"
db.uci.sect.console          = "console"

db.ubus                             = {}
db.ubus.object                      = {}
db.ubus.method                      = {}
db.ubus.object.system               = "system"
db.ubus.method.info                 = "info"
db.ubus.object.oasis                = "oasis"
db.ubus.method.load_icon_info       = "load_icon_info"
db.ubus.method.select_icon          = "select_icon"
db.ubus.method.update_sysmsg_data   = "update_sysmsg_data"
db.ubus.method.load_sysmsg_data     = "load_sysmsg_data"
db.ubus.method.delete_icon          = "delete_icon"
db.ubus.method.confirm              = "confirm"
db.ubus.method.config               = "config"
db.ubus.method.load_sysmsg_list     = "load_sysmsg_list"
db.ubus.method.add_sysmsg_data      = "add_sysmsg_data"
db.ubus.method.delete_sysmsg_data   = "delete_sysmsg_data"
db.ubus.object.oasis_chat           = "oasis.chat"
db.ubus.method.delete               = "delete"
db.ubus.method.list                 = "list"
db.ubus.method.append               = "append"
db.ubus.method.load                  = "load"
db.ubus.method.create               = "create"
db.ubus.object.oasis_title          = "oasis.title"
db.ubus.method.auto_set             = "auto_set"
db.ubus.method.manual_set           = "manual_set"

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
ai.service.gemini.name              = "Google Gemini"
ai.service.gemini.endpoint          = "https://generativelanguage.geminiapis.com"
ai.service.openrouter               = {}
ai.service.openrouter.name          = "OpenRouter"
ai.service.openrouter.endpoint      = "https://openrouter.ai/api/v1/chat/completions"
ai.format                           = {}
ai.format.chat                      = "chat"
ai.format.prompt                    = "prompt"
ai.format.call                      = "call"
ai.format.output                    = "output"
ai.format.rpc_output               = "rpc-output"
ai.format.title                     = "ai_create_title"

local endpoint = {}
endpoint.type = {}
endpoint.type.default   = "default"
endpoint.type.custom    = "custom"

local flag = {}
flag.apply = {}
flag.apply.complete = "/tmp/oasis/apply/complete"
flag.apply.rollback = "/tmp/oasis/apply/rollback"
flag.unload = {}
flag.unload.plugin = "/tmp/oasis/reboot_required"

local role = {}
role.system      = "system"
role.user        = "user"
role.assistant   = "assistant"
role.unknown     = "unknown"

local status        = {}
status.ok           = "OK"
status.error        = "ERROR"
status.not_found    = "NOT FOUND"

local rollback  = {}
rollback.dir                = "/etc/oasis/backup/"
rollback.list_item_name     = "list"
rollback.uci_cmd_json       = "uci_list.json"
rollback.backup_uci_list    = "backup_uci_list.json"

local GENERATE_ID_MAX_RETRY = 5


local function generate_random_id(method)

    local id = ""

    if method == "urandom" then
        id = sys.exec("tr -dc '0-9' < /dev/urandom | head -c 10 > /tmp/random_number && cat /tmp/random_number")
        id = id:gsub("\n", "")
    elseif method == "seed" then
        math.randomseed(os.time() + os.clock() * 1000000)
        -- math.randomseed(os.time() + tonumber(tostring({}):sub(8), 16))
        for _ = 1, 10 do
            id = id .. tostring(math.random(0, 9))
        end
    end

    return id
end

local select_service_obj = function()

    local target = nil
    local service = uci:get_first(db.uci.cfg, db.uci.sect.service, "name", "")

    if service == ai.service.ollama.name then
        target = require("oasis.chat.service.ollama")
    elseif service == ai.service.openai.name then
        target = require("oasis.chat.service.openai")
    elseif service == ai.service.anthropic.name then
        target = require("oasis.chat.service.anthropic")
    elseif service == ai.service.gemini.name then
        target = require("oasis.chat.service.gemini")
    elseif service == ai.service.openrouter.name then
        target = require("oasis.chat.service.openrouter")
    end

    return target
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

local generate_chat_id = function()

    local id
    local retry = GENERATE_ID_MAX_RETRY

    local is_exist

    -- debug:log("oasis.log", "\n --- [common.lua][generate_chat_id] --- ")

    repeat
        retry = retry - 1

        id = generate_random_id("urandom")
        -- id = generate_random_id("seed")

        -- debug:log("oasis.log", "id = " .. id)

        is_exist = search_chat_id(id)

    until (not is_exist) or (retry <= 0)

    if is_exist then
        id = ""
    end

    return id
end

local generate_service_id = function(method)

    local oasis_cfg_tbl = uci:get_all(db.uci.cfg)

    local search_service_id = function(id)

        for sect, sect_tbl in pairs(oasis_cfg_tbl) do
            for opt, value in pairs(sect_tbl) do
                if (opt == ".type") and (value == "service") then
                    if (oasis_cfg_tbl[sect].identifier) and (id == oasis_cfg_tbl[sect].identifier) then
                        -- debug:log("oasis.log", "Same service id exist!")
                        return true
                    end
                end
            end
        end

        return false
    end

    local id
    local retry = GENERATE_ID_MAX_RETRY

    local is_exist

    -- debug:log("oasis.log", "\n --- [common.lua][generate_chat_id] --- ")

    repeat
        retry = retry - 1

        id = generate_random_id(method)

        -- debug:log("oasis.log", "id = " .. id)

        is_exist = search_service_id(id)

    until (not is_exist) or (retry <= 0)

    if is_exist then
        id = ""
    end

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

local function check_server_loaded(server_name)

    -- timeout: 1000ms
    local conn = ubus.connect(nil, 1000)
    if not conn then
        return false
    end

    local objects = conn:objects()
    for _, obj in ipairs(objects) do
        if obj == server_name then
            conn:close()
            return true
        end
    end

    conn:close()
    return false
end

local check_unloaded_plugin = function()
    return misc.check_file_exist(flag.unload.plugin)
end

local check_prepare_oasis = function()

    -- Check standard ubus server
    if  (not check_server_loaded("oasis"))
            or (not check_server_loaded("oasis.chat")) 
            or (not check_server_loaded("oasis.title")) then
        return false
    end

    if check_unloaded_plugin() then
        return true
    end

    -- Check plugin ubus server
    local is_loaded_plugin_server = true
    uci:foreach(db.uci.cfg, db.uci.sect.tool, function(tbl)
        if (tbl.server) and (not check_server_loaded(tbl.server)) then
            is_loaded_plugin_server = false
        end
    end)

    if not is_loaded_plugin_server then
        return false
    end

    return true
end

return {
    db = db,
    ai = ai,
    endpoint = endpoint,
    flag = flag,
    role = role,
    select_service_obj = select_service_obj,
    status = status,
    rollback = rollback,
    get_target_id_section = get_target_id_section,
    search_chat_id = search_chat_id,
    load_conf_file = load_conf_file,
    update_conf_file = update_conf_file,
    generate_chat_id = generate_chat_id,
    generate_service_id = generate_service_id,
    check_chat_format = check_chat_format,
    check_server_loaded = check_server_loaded,
    check_prepare_oasis = check_prepare_oasis,
    check_unloaded_plugin = check_unloaded_plugin,
}