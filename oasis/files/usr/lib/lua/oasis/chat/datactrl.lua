#!/usr/bin/env lua

local util      = require("luci.util")
local uci       = require("luci.model.uci").cursor()
local common    = require("oasis.common")
local misc      = require("oasis.chat.misc")
local ous       = require("oasis.unified.chat.schema")
local debug     = require("oasis.chat.debug")

local sysmsg_info = {}
sysmsg_info.fix_key = {}
sysmsg_info.fix_key.casual = "casual"

local get_ai_service_cfg = function(arg, opts)

    debug:log("oasis.log", "get_ai_service_cfg", "\n--- [datactrl.lua][get_ai_service_cfg] ---")

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
                local endpoint_type = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "openai_endpoint_type", "") or ""
                if endpoint_type == common.endpoint.type.default then
                    cfg.endpoint = common.ai.service.openai.endpoint
                elseif endpoint_type == common.endpoint.type.custom then
                    cfg.endpoint = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "openai_custom_endpoint")
                end
                break
            elseif cfg.service == ai_ref.service.anthropic.name then
                local endpoint_type = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "anthropic_endpoint_type", "") or ""
                if endpoint_type == common.endpoint.type.default then
                    cfg.endpoint = common.ai.service.anthropic.endpoint
                elseif endpoint_type == common.endpoint.type.custom then
                    cfg.endpoint = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "anthropic_custom_endpoint")
                end
                break
            elseif cfg.service == ai_ref.service.gemini.name then
                local endpoint_type = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "gemini_endpoint_type", "") or ""
                if endpoint_type == common.endpoint.type.default then
                    cfg.endpoint = common.ai.service.gemini.endpoint
                elseif endpoint_type == common.endpoint.type.custom then
                    cfg.endpoint = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "gemini_custom_endpoint")
                end
                break
            elseif cfg.service == ai_ref.service.openrouter.name then
                local endpoint_type = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "openrouter_endpoint_type", "") or ""
                if endpoint_type == common.endpoint.type.default then
                    cfg.endpoint = common.ai.service.openrouter.endpoint
                elseif endpoint_type == common.endpoint.type.custom then
                    cfg.endpoint = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "openrouter_custom_endpoint")
                end
                break
            end
        end
    end

    -- debug:log("oasis.log", "opts dump")
    -- debug:dump("oasis.log", opts)
    -- debug:log("oasis.log", "arg")
    -- debug:dump("oasis.log", arg)

    if arg then
        cfg.id = arg.id
        if opts and ((opts.format == ai_ref.format.output) or (opts.format == ai_ref.format.rpc_output)) then
            local default_sysmsg_key = uci:get(common.db.uci.cfg, common.db.uci.sect.console, "chat") or "default"
            if (arg.sysmsg_key and (#arg.sysmsg_key > 0)) then
                debug:log("oasis.log", "get_ai_service_cfg", "set sysmsg_key: " .. arg.sysmsg_key)
                cfg.sysmsg_key = arg.sysmsg_key
            else
                cfg.sysmsg_key = default_sysmsg_key
                debug:log("oasis.log", "get_ai_service_cfg", "use default sysmsg_key: " .. cfg.sysmsg_key)
            end
        end
    end

    return cfg
end

local load_chat_data = function(service)

    debug:log("oasis.log", "load_chat_data", "\n--- [datactrl.lua][load_chat_data] ---")

    local cfg = service:get_config()
    local format = service:get_format()
    local chat = {}

    if cfg and cfg.id and (#cfg.id ~= 0) then
        debug:log("oasis.log", "load_chat_data", "load chat data!! (id = )" .. tostring(cfg.id))
        chat = util.ubus("oasis.chat", "load", {id = cfg.id})
    end

    chat.model = cfg.model

    if (cfg.service == common.ai.service.ollama.name)
        or (cfg.service == common.ai.service.openai.name)
        or (cfg.service == common.ai.service.gemini.name) then
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
    end

    -- TODO: Separate the get_ai_service_cfg function into load_service and load_chat_history and print.
    if (format ~= common.ai.format.output) and (format ~= common.ai.format.rpc_output) then
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
    -- Robust creation even if tool calls caused system/user/assistant counts to vary
    local count = (chat.messages and #chat.messages) or 0
    local get = function(idx)
        if idx >= 1 and idx <= count then return chat.messages[idx].role, chat.messages[idx].content end
        return "", ""
    end
    local message = {}
    if (service.sysmsg_key) and (#service.sysmsg_key > 0) and (service.sysmsg_key == sysmsg_info.fix_key.casual) then
        local r2, c2 = get(count-1)
        local r3, c3 = get(count)
        message.role1, message.content1 = r2, c2
        message.role2, message.content2 = r3, c3
        message.role3, message.content3 = "", ""
    else
        local r1, c1 = get(count-2)
        local r2, c2 = get(count-1)
        local r3, c3 = get(count)
        message.role1, message.content1 = r1, c1
        message.role2, message.content2 = r2, c2
        message.role3, message.content3 = r3, c3
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

    debug:log("oasis.log", "record_chat_data", "\n--- [datactrl.lua][record_chat_data] ---")
    debug:log("oasis.log", "record_chat_data", tostring(#chat.messages))
    debug:dump("oasis.log", chat)

    -- First Conversation
    if #chat.messages == 3 then
        local chat_id = create_chat_file(service, chat)
        set_chat_title(service, chat_id)
    -- Conversation after the second
    elseif (#chat.messages >= 5) and ((#chat.messages % 2) == 1) then
        debug:dump("oasis.log", chat)
        ous.append_chat_data(service, chat)
    end
end

return {
    get_ai_service_cfg = get_ai_service_cfg,
    load_chat_data = load_chat_data,
    create_chat_file = create_chat_file,
    set_chat_title = set_chat_title,
    record_chat_data = record_chat_data,
}