#!/usr/bin/env lua

-- local uci = require("luci.model.uci").cursor()
local curl      = require("cURL.safe")
local common    = require("oasis.common")
local jsonc     = require("luci.jsonc")
local datactrl  = require("oasis.chat.datactrl")
local util      = require("luci.util")
-- local debug     = require("oasis.chat.debug")

local post_to_server = function(service, user_msg_json, callback)
    local cfg = service:get_config()
    local easy = curl.easy()
    -- os.execute("echo " .. cfg.endpoint .. " /tmp/refactor.log")
    easy:setopt_url(cfg.endpoint)
    easy:setopt_writefunction(callback)
    -- ollama or openai
    if cfg.api_key and (type(cfg.api_key) == "string") and (#cfg.api_key > 0) then
        if (cfg.service == common.ai.service.ollama.name)
            or (cfg.service == common.ai.service.openai.name)
            or (cfg.service == common.ai.service.anthropic.name) then

            easy:setopt_httpheader({
                "Content-Type: application/json",
                "Authorization: Bearer " .. cfg.api_key
            })

        elseif cfg.service == common.ai.service.gemini.name then
            easy:setopt_httpheader({
                "Content-Type: application/json",
                "Authorization: Bearer " .. cfg.api_key
            })
        end
    end
    easy:setopt_httppost(curl.form())
    easy:setopt_postfields(user_msg_json)
    local success = easy:perform()

    if not success then
        print("\27[31m" .. "Error" .. "\27[0m")
    end

    easy:close()
end

local get_to_server = function(url, callback)
    local easy = curl.easy()
    easy:setopt_url(url)
    easy:setopt_writefunction(callback)
    easy:perform()
    easy:close()
end

local send_user_msg = function(service, chat)

    local recv_raw_msg = ""
    local usr_msg_json = jsonc.stringify(chat, false)
    local format = service:get_format()

    service:init_msg_buffer()

    -- Post
    post_to_server(service, usr_msg_json, function(chunk)

        local text_for_console
        local text_for_webui

        text_for_console, text_for_webui, recv_raw_msg = service:recv_ai_msg(chunk)

        -- output console
        if (format == common.ai.format.chat)
            or (format == common.ai.format.prompt)
            or (format == common.ai.format.call) then
            if (text_for_console) and (#text_for_console) > 0 then
                io.write(text_for_console)
                io.flush()
            end

        -- output webui
        elseif (format == common.ai.format.output) then
            if (text_for_webui) and (#text_for_webui > 0) then
                io.write(text_for_webui)
                io.flush()
            end
        end
    end)

    return recv_raw_msg
end


local chat_with_ai = function(service, chat)

    -- debug:log("oasis.log", "\n--- [transfer.lua][chat_with_ai] ---")

    local format = service:get_format()

    local output_llm_model = function(model)
        print("\n\27[34m" .. model .. "\27[0m")
    end

    service:setup_system_msg(chat)

    if format == common.ai.format.chat then
        output_llm_model(chat.model)
    end

    -- debug:log("oasis.log", "dump chat date")
    -- debug:dump("oasis.log", chat)

    -- send user message and receive ai message
    local ai= send_user_msg(service, chat)

    -- debug:dump("oasis.log", ai)

    local new_chat_info = nil

    if format == common.ai.format.chat then
        -- debug:log("oasis.log", "#ai.message = " .. #ai.message)
        -- debug:log("oasis.log", "ai.message = " .. ai.message)
        if service:setup_msg(chat, ai) then
            datactrl.record_chat_data(service, chat)
        end
    elseif format == common.ai.format.output then

        local cfg = service:get_config()

        -- debug:dump("oasis.log", cfg)

        if (not cfg.id) or (#cfg.id == 0) then
            -- debug:log("oasis.log", "first called")
            if service:setup_msg(chat, ai) then
                local chat_info = {}
                chat_info.id = datactrl.create_chat_file(service, chat)
                local result = util.ubus("oasis.title", "auto_set", {id = chat_info.id})
                chat_info.title = result.title
                new_chat_info = jsonc.stringify(chat_info, false)
            end
        else
            -- debug:log("oasis.log", "second called")
            if service:setup_msg(chat, ai) then
                -- debug:log("oasis.log", "call append_chat_data")
                service:append_chat_data(chat)
            end
        end
    elseif format == common.ai.format.title then
        -- debug:log("oasis.log", ai.message)
        ai.message = ai.message:gsub("%s+", "")
    end

    return new_chat_info, ai.message
end

return {
    post_to_server = post_to_server,
    get_to_server = get_to_server,
    send_user_msg = send_user_msg,
    chat_with_ai = chat_with_ai,
}