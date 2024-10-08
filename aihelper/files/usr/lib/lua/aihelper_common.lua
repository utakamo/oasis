#!/usr/bin/env lua

local uci = require("luci.model.uci").cursor()

local status = {
    ok = "OK",
    error = "ERROR",
    not_found = "NOT FOUND",
}

local get_aihelper_conf = function()
    local conf = {}
    conf.path = uci:get("aihelper", "storage", "path")
    conf.prefix = uci:get("aihelper", "storage", "prefix")
    conf.model = uci:get_first("aihelper", "service", "model")
    conf.url = uci:get_first("aihelper", "service", "url")
    return conf
end

local get_target_id_section = function(id)

    local unnamed_section = ""

    uci:foreach("aihelper", "chat", function(info)
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

    uci:foreach("aihelper", "chat", function(info)
        -- debug_log("file: " .. info.id)
        if id == info.id then
            is_search = true
        end
    end)

    return is_search
end

return {
    status = status,
    get_aihelper_conf = get_aihelper_conf,
    get_target_id_section = get_target_id_section,
    normalize_path = normalize_path,
    search_chat_id = search_chat_id,
}