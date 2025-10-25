#!/usr/bin/env lua

local jsonc     = require("luci.jsonc")
local util      = require("luci.util")
local uci       = require("luci.model.uci").cursor()
local common    = require("oasis.common")
-- local debug     = require("oasis.chat.debug")

------------------------------
-- [Used from oasis object] --
------------------------------
local retrieve_config = function()
    local storage_tbl = uci:get_all(common.db.uci.cfg, common.db.uci.sect.storage)
    local storage_json = jsonc.stringify(storage_tbl)
    return storage_json
end

local retrieve_icon_info = function(path, format)
        local data = common.load_conf_file(path)

        if (not data) or (not data.icons.path) or (not data.icons.using) then
            if (format) and (format == "json") then
                return jsonc.stringify({ status = common.status.not_found })
            end

            return { status = common.status.not_found }
        end

        local icon_tbl = {}
        icon_tbl.ctrl = {}
        icon_tbl.ctrl.path = data.icons.path
        icon_tbl.ctrl.using = data.icons.using

        icon_tbl.list = {}

        for key, img_name in pairs(data.icons) do
            if key:match("^icon_%d+$") then
                icon_tbl.list[key] = img_name
            end
        end

        local icon_json = jsonc.stringify(icon_tbl)

        if (format) and (format == "json")  then
            return icon_json
        end

        return icon_tbl
end

local retrieve_sysmsg = function(path, format)

    -- debug:log("oasis.log", "\n--- [util.lua][retrieve_sysmsg] ---")

    local sysmsg_tbl = common.load_conf_file(path)

    if not sysmsg_tbl then
        if (format) and (format == "json")  then
            return jsonc.stringify({ status = common.status.not_found })
        end

        return { status = common.status.not_found }
    end

    -- debug:dump("oasis.log", sysmsg_tbl)

    local sysmsg_json = jsonc.stringify(sysmsg_tbl)

    if (format) and (format == "json") then
        return sysmsg_json
    end

    return sysmsg_tbl
end
local retrieve_sysmsg_info = function(path, format)
    local data_tbl = common.load_conf_file(path)

    if not data_tbl then
        if (format) and (format == "json")  then
            return jsonc.stringify({ status = common.status.not_found })
        end

        return { status = common.status.not_found }
    end

    local sysmsg_array = {}

    for key, tbl in pairs(data_tbl) do
        if tbl.title then
            table.insert(sysmsg_array, {
                key = key,
                title = tbl.title
            })
        end
    end

    table.sort(sysmsg_array, function(a, b)
        if a.key == "default" then return true end
        if b.key == "default" then return false end
        return a.key < b.key
    end)

    local result_tbl = { sysmsg = sysmsg_array }

    local sysmsg_json = jsonc.stringify(result_tbl)

    if (format) and (format == "json")  then
        return sysmsg_json
    end

    return result_tbl.sysmsg
end

local retrieve_chat_info = function(format)
    local chat_list_tbl = {}
    chat_list_tbl.item = {}

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.chat, function(info)
        chat_list_tbl.item[#chat_list_tbl.item + 1] = {}
        chat_list_tbl.item[#chat_list_tbl.item].id = info.id or "unknown"
        chat_list_tbl.item[#chat_list_tbl.item].title = info.title or "--"
    end)

    local chat_list_json = jsonc.stringify(chat_list_tbl)

    if format == "json" then
        return chat_list_json
    end

    return chat_list_tbl
end

local retrieve_service_info = function(format)

    local data = uci:get_all(common.db.uci.cfg)

    if not data then
        if (format) and (format == "json")  then
            return jsonc.stringify({ status = "Failed to load config" })
        end

        return { status = "Failed to load config" }
    end

    local service_names = {}
    for name, tbl in pairs(data) do
        if tbl[".type"] == "service" and type(name) == "string" and name:match("^cfg%x%x%x%x%x%x$") then
            table.insert(service_names, name)
        end
    end

    table.sort(service_names, function(a, b)
        local a_num = tonumber(a:sub(4), 16)
        local b_num = tonumber(b:sub(4), 16)
        return a_num < b_num
    end)

    local service_list_tbl = {}
    for _, name in ipairs(service_names) do
        local entry = data[name]
        service_list_tbl[#service_list_tbl + 1] = {
            identifier = entry.identifier,
            name = entry.name,
            model = entry.model
        }
    end

    local service_list_json = jsonc.stringify(service_list_tbl)

    if (format) and (format == "json")  then
        return service_list_json
    end

    return service_list_tbl
end

local retrieve_uci_config = function(format)

    -- Currently, the only removal target in the uci config list is oasis and rpcd.
    -- Add the names of uci configs that you don't want to teach AI here.
    local black_list = {
        "oasis",
        "rpcd",
    }

    local list_tbl = util.ubus("uci", "configs", {})

    if (not list_tbl) or (not list_tbl.configs) then
        if (format) and (format == "json") then
            return jsonc.stringify({ error = "No uci list" })
        end

        return { error = "No uci list" }
    end

    for index = #list_tbl.configs, 1, -1 do
        for _, exclude_item in ipairs(black_list) do
            if list_tbl.configs[index] == exclude_item then
                table.remove(list_tbl.configs, index)
                break
            end
        end
    end

    local list_json = jsonc.stringify(list_tbl)

    if (format) and (format == "json") then
        return list_json
    end

    return list_tbl.configs
end

local parse_uci_cmd_sequence = function(message, format)
    local misc = require("oasis.chat.misc")

    local is_exist = misc.check_file_exist("/usr/lib/lua/oasis/chat/filter.lua")

    if not is_exist then
        return nil
    end

    local filter    = require("oasis.chat.filter")
    local uci_cmd_notification = {}
    uci_cmd_notification.uci_list = filter.uci_cmd_filter(message)
    uci_cmd_notification.uci_notify = filter.check_uci_list_exist(uci_cmd_notification.uci_list)
    if uci_cmd_notification.uci_notify then
        if (format) and (format == "json") then
            return jsonc.stringify(uci_cmd_notification)
        end

        return uci_cmd_notification
    end

    local notification = {}
    notification.status = "No Parsing ..."

    if (format) and (format == "json") then
        return jsonc.stringify(notification)
    end

    return notification
end

return {
    retrieve_config         = retrieve_config,
    retrieve_icon_info      = retrieve_icon_info,
    retrieve_sysmsg         = retrieve_sysmsg,
    retrieve_sysmsg_info    = retrieve_sysmsg_info,
    retrieve_chat_info      = retrieve_chat_info,
    retrieve_service_info   = retrieve_service_info,
    retrieve_uci_config     = retrieve_uci_config,
    parse_uci_cmd_sequence  = parse_uci_cmd_sequence,
}