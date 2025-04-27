#!/usr/bin/env lua

local util      = require("luci.util")
local uci       = require("luci.model.uci").cursor()
local common    = require("oasis.common")

local sysmsg_info = {}
sysmsg_info.fix_key = {}
sysmsg_info.fix_key.casual = "casual"

local retrieve_ai_service_cfg = function(arg, format)


    local cfg = {}
    cfg.identifer   = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "identifer", "")
    cfg.api_key     = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "api_key", "")
    cfg.service     = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "name", "")
    cfg.model       = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "model", "")

    if cfg.service == common.ai.service.ollama.name then
        cfg.endpoint = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "ollama_endpoint")
    elseif cfg.service == common.ai.service.openai.name then
        cfg.endpoint = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "openai_endpoint")
    elseif cfg.service == common.ai.service.anthropic.name then
        cfg.endpoint = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "anthropic_endpoint")
    elseif cfg.service == common.ai.service.gemini.name then
        cfg.endpoint = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "gemini_endpoint")
    end

    -- TODO
    -- cfg.endpoint = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "endpoint")

    cfg.id = arg.id

    if format == common.ai.format.output then
        if (arg.sysmsg_key and (#arg.sysmsg_key > 0)) then
            cfg.sysmsg_key = arg.sysmsg_key
            -- os.execute("echo " .. cfg.sysmsg_key .. " >> /tmp/sysmsg.log")
        end
    end

    return cfg
end

local load_chat_data = function(service)

    local cfg = service:get_config()
    local format = service:get_format()
    local chat = {}

    if cfg and cfg.id and (#cfg.id ~= 0) then
        chat = util.ubus("oasis.chat", "load", {id = cfg.id})
    end

    chat.model = cfg.model

    if (cfg.service == common.ai.service.ollama.name)
        or (cfg.service == common.ai.service.openai.name)
        or (cfg.service == common.ai.service.anthropic.name) then
        -- New Chat - initialize
        if not chat.messages then
            chat.messages = {}
        end
    elseif (cfg.service == common.ai.service.anthropic.name) then
        local max_tokens = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "max_tokens", "1000")
        local type = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "type", "disabled")
        local budget_tokens = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "budget_tokens", "1000")
        -- New Chat - initialize
        if not chat.messages then
            chat.max_tokens = max_tokens
            chat.stream = true
            chat.max_tokens = {
                type = type,
                budget_tokens = budget_tokens
            }
            chat.messages = {}
        end
    elseif (cfg.service == common.ai.service.gemini.name) then
        -- New Chat - initialize
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

local create_chat_file = function(service, chat)
    -- TODO:
    -- Update to allow chat files to be created even when role:system is not present.
    local message = {}
    if (service.sysmsg_key) and (#service.sysmsg_key > 0) and (service.sysmsg_key == sysmsg_info.fix_key.casual) then
        -- os.execute("echo \"no system message\" >> /tmp/oasis-create-chat-file.log")
        message.role1 = chat.messages[#chat.messages - 1].role
        message.content1 = chat.messages[#chat.messages - 1].content
        message.role2 = chat.messages[#chat.messages].role
        message.content2 = chat.messages[#chat.messages].content
        message.role3 = ""
        message.content3 = ""
    else
        -- os.execute("echo \"system message\" >> /tmp/oasis-create-chat-file.log")
        message.role1 = chat.messages[#chat.messages - 2].role
        message.content1 = chat.messages[#chat.messages - 2].content
        message.role2 = chat.messages[#chat.messages - 1].role
        message.content2 = chat.messages[#chat.messages - 1].content
        message.role3 = chat.messages[#chat.messages].role
        message.content3 = chat.messages[#chat.messages].content
    end

    -- os.execute("echo " .. message.role1 .. " >> /tmp/oasis-message.log")
    -- os.execute("echo \"" .. message.content1 .. "\" >> /tmp/oasis-message.log")
    -- os.execute("echo " .. message.role2 .. " >> /tmp/oasis-message.log")
    -- os.execute("echo \"" .. message.content2 .. "\" >> /tmp/oasis-message.log")
    -- os.execute("echo " .. message.role3 .. " >> /tmp/oasis-message.log")
    -- os.execute("echo \"" .. message.content3 .. "\" >> /tmp/oasis-message.log")

    local result = util.ubus("oasis.chat", "create", message)
    service.id = result.id
    return result.id
end

local set_chat_title = function(chat_id)
    local request = util.ubus("oasis.title", "auto_set", {id = chat_id})
    local announce =  "\n" .. "\27[1;37;44m" .. "Title:"
    announce = announce  .. "\27[1;33;44m" .. request.title
    announce = announce .. "  \27[1;37;44m" .. "ID:"
    announce = announce .. "\27[1;33;44m" .. chat_id
    announce = announce .. "\27[0m"
    io.write("\n" .. announce .. "\n")
    io.flush()
end

local record_chat_data = function(service, chat)

    -- print("#chat.messages = " .. #chat.messages)

    -- First Conversation (#chat.messages == 3)
    -- chat.messages[1] ... system message
    -- chat.messages[2] ... user message
    -- chat.messages[3] ... ai message <---- Save chat data

    -- Conversation after the second (#chat.messages >= 5) and ((#chat.messages % 2) == 1)
    -- chat.messages[4] ... user message
    -- chat.messages[5] ... ai message <---- Save chat data
    -- chat.messages[6] ... user message
    -- chat.messages[7] ... ai message <---- Save chat data

    -- First Conversation
    if #chat.messages == 3 then
        local chat_id = create_chat_file(service, chat)
        set_chat_title(chat_id)
    -- Conversation after the second
    elseif (#chat.messages >= 5) and ((#chat.messages % 2) == 1) then
        service:append_chat_data(chat)
    end
end

return {
    retrieve_ai_service_cfg = retrieve_ai_service_cfg,
    load_chat_data = load_chat_data,
    create_chat_file = create_chat_file,
    record_chat_data = record_chat_data,
}