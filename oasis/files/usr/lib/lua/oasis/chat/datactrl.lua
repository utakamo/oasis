#!/usr/bin/env lua

local util      = require("luci.util")
local uci       = require("luci.model.uci").cursor()
local common    = require("oasis.common")
local misc      = require("oasis.chat.misc")
local debug     = require("oasis.chat.debug")

local sysmsg_info = {}
sysmsg_info.fix_key = {}
sysmsg_info.fix_key.casual = "casual"

local get_ai_service_cfg = function(arg, opts)

    local cfg = {}
    local uci_ref = common.db.uci
    local ai_ref = common.ai

    cfg.identifier = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "identifier", "") or ""
    cfg.api_key    = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "api_key", "") or ""
    cfg.service    = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "name", "") or ""
    cfg.model      = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "model", "") or ""
    cfg.ipaddr     = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "ipaddr", "") or ""

    if opts and opts.with_storage then
        cfg.path   = uci:get(uci_ref.cfg, uci_ref.sect.storage, "path")
        cfg.prefix = uci:get(uci_ref.cfg, uci_ref.sect.storage, "prefix")
    end

    for _, service in pairs(ai_ref.service) do
        if cfg.service == service.name then
            if cfg.service == ai_ref.service.ollama.name then
                cfg.endpoint = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "ollama_endpoint")
                break
            elseif cfg.service == ai_ref.service.openai.name then
                cfg.endpoint = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "openai_endpoint")
                break
            elseif cfg.service == ai_ref.service.anthropic.name then
                cfg.endpoint = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "anthropic_endpoint")
                break
            elseif cfg.service == ai_ref.service.gemini.name then
                cfg.endpoint = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "gemini_endpoint")
                break
            end
        end
    end

    if arg then
        cfg.id = arg.id
        if opts and opts.format == (ai_ref.format and ai_ref.format.output) then
            if (arg.sysmsg_key and (#arg.sysmsg_key > 0)) then
                cfg.sysmsg_key = arg.sysmsg_key
            end
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

    -- TODO: Separate the get_ai_service_cfg function into load_service and load_chat_history and print.
    if format ~= common.ai.format.output then
        -- todo: update
        for _, tbl in ipairs(chat.messages) do
            if tbl.role == common.role.user then
                print("You :" .. tbl.content)
            elseif tbl.role == common.role.assistant then

                local content = misc.markdown(nil, tbl.content)

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

local set_chat_title = function(service, chat_id)
    local request = util.ubus("oasis.title", "auto_set", {id = chat_id})

    if request.status == common.status.error then
        io.write("\n\27[1;33;41m Title Creation: Error \27[0m\n")
        return
    end

    service:set_chat_id(chat_id)

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

    debug.log("append_chat_data.log", #chat.messages)
    debug.dump("append_chat_data.log", chat)

    -- First Conversation
    if #chat.messages == 3 then
        local chat_id = create_chat_file(service, chat)
        set_chat_title(service, chat_id)
    -- Conversation after the second
    elseif (#chat.messages >= 5) and ((#chat.messages % 2) == 1) then
        debug.dump("append_chat_data_dump.log", chat)
        service:append_chat_data(chat)
    end
end

return {
    get_ai_service_cfg = get_ai_service_cfg,
    load_chat_data = load_chat_data,
    create_chat_file = create_chat_file,
    record_chat_data = record_chat_data,
}