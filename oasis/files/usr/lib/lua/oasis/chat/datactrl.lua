#!/usr/bin/env lua

local util      = require("luci.util")
local uci       = require("luci.model.uci").cursor()
local common    = require("oasis.common")
local misc      = require("oasis.chat.misc")
local ous       = require("oasis.unified.chat.schema")
local debug     = require("oasis.chat.debug")
local chat_error = require("oasis.chat.error")

local M = {}

local sysmsg_info = {}
sysmsg_info.fix_key = {}
sysmsg_info.fix_key.casual = "casual"

local TITLE_AUTO_SET_TIMEOUT_MS = 120000
local ANTHROPIC_DEFAULT_MAX_TOKENS = 1024
local ANTHROPIC_MIN_BUDGET_TOKENS = 1024

local function parse_positive_integer(value)
    local text = tostring(value or "")
    if not text:match("^%d+$") then
        return nil
    end

    local number = tonumber(text)
    if not number or number <= 0 or number >= math.huge or number ~= math.floor(number) then
        return nil
    end

    return number
end

local function normalize_anthropic_thinking(value)
    value = tostring(value or ""):lower()
    if value == "disabled" or value == "enabled" or value == "adaptive" then
        return value
    end

    return nil
end

local function load_anthropic_config(cfg, service_section)
    local raw_max_tokens = uci:get(
        common.db.uci.cfg, service_section, "max_tokens"
    )
    local max_tokens
    if raw_max_tokens == nil or raw_max_tokens == "" then
        max_tokens = ANTHROPIC_DEFAULT_MAX_TOKENS
    else
        max_tokens = parse_positive_integer(raw_max_tokens)
        if not max_tokens then
            cfg.anthropic_config_error =
                "Anthropic max_tokens must be a positive integer."
        end
    end

    local raw_thinking = uci:get(
        common.db.uci.cfg, service_section, "thinking"
    )
    local thinking
    if raw_thinking ~= nil and raw_thinking ~= "" then
        thinking = normalize_anthropic_thinking(raw_thinking)
        if not thinking then
            cfg.anthropic_config_error =
                "Anthropic thinking must be disabled, enabled, or adaptive."
        end
    end

    -- Older service sections stored the thinking mode in "type". Keep this
    -- read-only fallback so loading a legacy service does not require a bulk
    -- UCI migration.
    if raw_thinking == nil or raw_thinking == "" then
        thinking = normalize_anthropic_thinking(
            uci:get(common.db.uci.cfg, service_section, "type")
        ) or "disabled"
    end

    cfg.max_tokens = max_tokens
    cfg.thinking = thinking
    cfg.budget_tokens = nil

    if thinking == "enabled" then
        local budget_tokens = parse_positive_integer(
            uci:get(common.db.uci.cfg, service_section, "budget_tokens")
        )

        if not budget_tokens
            or budget_tokens < ANTHROPIC_MIN_BUDGET_TOKENS then
            cfg.anthropic_config_error =
                "Anthropic budget_tokens must be an integer greater than or equal to 1024."
        elseif max_tokens and budget_tokens >= max_tokens then
            cfg.anthropic_config_error =
                "Anthropic budget_tokens must be less than max_tokens."
        elseif max_tokens then
            cfg.budget_tokens = budget_tokens
        end
    end
end

function M.get_ai_service_cfg(arg, opts)

    debug:log("oasis.log", "get_ai_service_cfg", "\n--- [datactrl.lua][get_ai_service_cfg] ---")

    local cfg = {}
    local uci_ref = common.db.uci
    local ai_ref = common.ai
    local service_section = uci:get_first(uci_ref.cfg, uci_ref.sect.service)

    cfg.identifier = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "identifier", "") or ""
    cfg.api_key    = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "api_key", "") or ""
    cfg.service    = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "name", "") or ""
    cfg.model      = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "model", "") or ""
    cfg.ipaddr     = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "ipaddr", "") or ""
    cfg.function_calling = service_section
        and uci:get(uci_ref.cfg, service_section, "function_calling")
        or "0"
    cfg.show_thinking = service_section
        and uci:get(uci_ref.cfg, service_section, "show_thinking")
        or "0"

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
                local custom_endpoint = uci:get_first(
                    uci_ref.cfg,
                    uci_ref.sect.service,
                    "openai_custom_endpoint",
                    ""
                ) or ""

                if endpoint_type ~= common.endpoint.type.default
                    and endpoint_type ~= common.endpoint.type.custom then
                    endpoint_type = (#custom_endpoint > 0)
                        and common.endpoint.type.custom
                        or common.endpoint.type.default
                end

                cfg.openai_api_mode = common.resolve_openai_api_mode(
                    uci:get_first(uci_ref.cfg, uci_ref.sect.service, "openai_api_mode", "") or "",
                    endpoint_type
                )

                if endpoint_type == common.endpoint.type.custom then
                    cfg.endpoint = custom_endpoint
                elseif cfg.openai_api_mode == common.ai.service.openai.api_mode.responses then
                    cfg.endpoint = common.ai.service.openai.responses_endpoint
                else
                    cfg.endpoint = common.ai.service.openai.chat_completions_endpoint
                end
                break
            elseif cfg.service == ai_ref.service.anthropic.name then
                local endpoint_type = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "anthropic_endpoint_type", "") or ""
                if endpoint_type == common.endpoint.type.default then
                    cfg.endpoint = common.ai.service.anthropic.endpoint
                elseif endpoint_type == common.endpoint.type.custom then
                    cfg.endpoint = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "anthropic_custom_endpoint")
                end
                load_anthropic_config(cfg, service_section)
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
            elseif cfg.service == ai_ref.service.lmstudio.name then
                cfg.endpoint = uci:get_first(uci_ref.cfg, uci_ref.sect.service, "lmstudio_endpoint")
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

function M.load_chat_data(service)

    debug:log("oasis.log", "load_chat_data", "\n--- [datactrl.lua][load_chat_data] ---")

    local cfg = service:get_config()
    local format = service:get_format()
    local chat = {}

    if cfg and cfg.id and (#cfg.id ~= 0) then
        debug:log("oasis.log", "load_chat_data", "load chat data!! (id = )" .. tostring(cfg.id))
        chat = util.ubus("oasis.chat", "load", {id = cfg.id})
    end

    chat.model = cfg.model

    -- New Chat - initialize
    if not chat.messages then
        chat.messages = {}
    end

    return chat
end

function M.create_chat_file(service, chat)
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
    if type(result) ~= "table"
        or result.status ~= common.status.ok
        or #tostring(result.id or "") == 0 then
        return nil, "oasis.chat create did not return a valid chat ID."
    end
    service.id = result.id
    return result.id, nil
end

function M.set_chat_title(service, chat_id)
    service:set_chat_id(chat_id)

    -- Title generation calls the selected AI service through oasis.title and may
    -- exceed the default ubus timeout on slow local LLMs. Use common.ubus_call()
    -- so this long-running ubus request has an explicit timeout.
    local request, err = common.ubus_call(
        common.db.ubus.object.oasis_title,
        common.db.ubus.method.auto_set,
        {id = chat_id},
        TITLE_AUTO_SET_TIMEOUT_MS
    )

    if (not request) or err or request.status == common.status.error then
        local title_err = chat_error.build(service, {
            phase = "title_generation",
            kind = "title_error",
            message = "Chat title generation failed.",
            provider_message = err or request and request.desc,
            can_continue = true,
        })
        debug:log("oasis.log", "set_chat_title", chat_error.format(title_err))
        io.write("\n\27[1;33;41m Title Creation: Error \27[0m\n")
        io.write(chat_error.format(title_err) .. "\n")
        io.flush()
        return
    end

    local announce =  "\n" .. "\27[1;37;44m" .. "Title:"
    announce = announce  .. "\27[1;33;44m" .. request.title
    announce = announce .. "  \27[1;37;44m" .. "ID:"
    announce = announce .. "\27[1;33;44m" .. chat_id
    announce = announce .. "\27[0m"
    io.write("\n" .. announce .. "\n")
    io.flush()
end

function M.record_chat_data(service, chat)

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

    -- debug:log("oasis.log", "record_chat_data", "\n--- [datactrl.lua][record_chat_data] ---")
    -- debug:log("oasis.log", "record_chat_data", tostring(#chat.messages))
    -- debug:dump("oasis.log", chat)

    -- First Conversation
    if #chat.messages == 3 then
        local chat_id, create_error = M.create_chat_file(service, chat)
        if not chat_id then
            return false, create_error
        end
        M.set_chat_title(service, chat_id)
        return true, nil
    -- Conversation after the second
    elseif (#chat.messages >= 5) and ((#chat.messages % 2) == 1) then
        -- debug:dump("oasis.log", chat)
        return ous.append_chat_data(service, chat)
    end
    return true, nil
end

return M
