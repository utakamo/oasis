#!/usr/bin/env lua

local util = require("luci.util")
local uci = require("luci.model.uci").cursor()
local common = require("oasis.common")

local retrieve_ai_service_cfg = function(arg, format)

    local cfg = {}
    cfg.api_key = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "api_key", "")
    cfg.service = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "name", "")

    if cfg.service == common.ai.service.ollama.name then
        local url = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "ipaddr", "") or ""
        cfg.endpoint = string.gsub(common.ai.service.ollama.endpoint, "%[x%.x%.x%.x%]", url)
    elseif cfg.service == common.ai.service.openai.name then
        cfg.endpoint = common.ai.service.openai.endpoint
    elseif cfg.service == common.ai.service.anthropic.name then
        cfg.endpoint = common.ai.service.anthropic.endpoint
    elseif cfg.service == common.ai.service.gemini.name then
        cfg.endpoint = common.ai.service.gemini.endpoint
    end

    cfg.id = arg.id

    if format == common.ai.format.output then
        if (arg.sysmsg_key and (#arg.sysmsg_key > 0)) then
            cfg.sysmsg_key = arg.sysmsg_key
            -- os.execute("echo " .. cfg.sysmsg_key .. " >> /tmp/sysmsg.log")
        end
    end

    return cfg
end


local load_chat_data = function(arg, format)

    local service = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "name", "")
    local chat = {}

    if arg and arg.id and (#arg.id ~= 0) then
        chat = util.ubus("oasis.chat", "load", {id = arg.id})
    end

    chat.model = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "model", "")

    if (service == common.ai.service.ollama.name)
        or (service == common.ai.service.openai.name)
        or (service == common.ai.service.anthropic.name) then
        if not chat.messages then
            chat.messages = {}
        end
    elseif (service == common.ai.service.gemini.name) then
        if not chat.contents then
            chat.contents = {}
            chat.contents.parts = {}
        end
    end

    -- TODO: Separate the retrieve_ai_service_cfg function into load_service and load_chat_history and print.
    if format ~= common.ai.format.output then
        -- todo: update
        for _, tbl in ipairs(chat.messages) do
            if tbl.role == common.role.user then
                print("You :" .. tbl.content)
            elseif tbl.role == common.role.assistant then

                local content = common.markdown(nil, tbl.content)

                print()
                print(chat.model)
                print(content)
            end
        end
    end

    return chat
end

return {
    retrieve_ai_service_cfg = retrieve_ai_service_cfg,
    load_chat_data = load_chat_data,
}