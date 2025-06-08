#!/usr/bin/env lua

local jsonc = require("luci.jsonc")
local uci = require("luci.model.uci").cursor()
local common = require("oasis.common")

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
    local sysmsg_tbl = common.load_conf_file(path)

    if not sysmsg_tbl then
        if (format) and (format == "json")  then
            return jsonc.stringify({ status = common.status.not_found })
        end

        return { status = common.status.not_found }
    end

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

    local icon_info_tbl = {}
    icon_info_tbl.key = {}
    icon_info_tbl.title = {}

    for key, tbl in pairs(data_tbl) do
        if tbl.title then
            icon_info_tbl.key[#icon_info_tbl.key + 1] = key
            icon_info_tbl.title[#icon_info_tbl.title + 1] = tbl.title
        end
    end

    local icon_info_json = jsonc.stringify(icon_info_tbl)

    if (format) and (format == "json")  then
        return icon_info_json
    end

    return icon_info_tbl
end

return {
    retrieve_config         = retrieve_config,
    retrieve_icon_info      = retrieve_icon_info,
    retrieve_sysmsg         = retrieve_sysmsg,
    retrieve_sysmsg_info    = retrieve_sysmsg_info,
}