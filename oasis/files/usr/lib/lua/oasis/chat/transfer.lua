#!/usr/bin/env lua

-- local uci = require("luci.model.uci").cursor()
local curl      = require("cURL.safe")
local common    = require("oasis.common")
local jsonc     = require("luci.jsonc")
local datactrl  = require("oasis.chat.datactrl")
local util      = require("luci.util")
local debug     = require("oasis.chat.debug")

-- Create a shallow copy of chat and drop transient messages before persisting
-- - Exclude role=="tool"
-- - Exclude role=="assistant" that contains tool_calls
local function clone_chat_without_tool_messages(chat)
    local cloned = {}
    for k, v in pairs(chat or {}) do
        if k ~= "messages" then
            cloned[k] = v
        end
    end
    cloned.messages = {}
    if chat and chat.messages then
        for _, m in ipairs(chat.messages) do
            local is_tool = (m.role == "tool")
            local is_assistant_toolcall = (m.role == "assistant" and m.tool_calls ~= nil)
            if (not is_tool) and (not is_assistant_toolcall) then
                table.insert(cloned.messages, m)
            end
        end
    end
    return cloned
end

local post_to_server = function(service, user_msg_json, callback)

    local cfg = service:get_config()
    local easy = curl.easy()

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

    -- current
    -- local usr_msg_json = jsonc.stringify(chat, false)

    local usr_msg_json = service:convert_schema(chat)

    -- Debug Message Json Log
    local debug_msg_json = jsonc.stringify(chat, true)
    debug:log("debug_msg_json.log", debug_msg_json)

    local format = service:get_format()

    service:init_msg_buffer()

    -- Post
    post_to_server(service, usr_msg_json, function(chunk)

        local text_for_console
        local text_for_webui

        text_for_console, text_for_webui, recv_raw_msg = service:recv_ai_msg(chunk)

        debug:log("post_to_server.log", text_for_console)
        debug:log("post_to_server.log", text_for_webui)

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

    debug:log("oasis.log", "\n--- [transfer.lua][chat_with_ai] ---")

    local format = service:get_format()

    local output_llm_model = function(model)
        print("\n\27[34m" .. model .. "\27[0m")
    end

    service:setup_system_msg(chat)

    if format == common.ai.format.chat then
        output_llm_model(chat.model)
    end

    debug:log("oasis.log", "dump chat data")
    debug:dump("oasis.log", chat)

    -- send user message and receive ai message
    local ai= send_user_msg(service, chat)

    debug:dump("oasis.log", ai)

    local new_chat_info = nil

    if format == common.ai.format.chat then
        -- debug:log("oasis.log", "#ai.message = " .. #ai.message)
        -- debug:log("oasis.log", "ai.message = " .. ai.message)
        if service:setup_msg(chat, ai) then
            datactrl.record_chat_data(service, chat)
        end
    elseif (format == common.ai.format.output) or (format == common.ai.format.rpc_output) then

        local cfg = service:get_config()

        debug:dump("oasis.log", cfg)

        if (not cfg.id) or (#cfg.id == 0) then
            debug:log("oasis.log", "first called")
            if ai and ai.tool_calls then
                -- When the model requested tool calls, do not create file yet
                -- Defer recording until the assistant returns a text response next time
                debug:log("oasis.log", "tool_calls detected; defer create_chat_file")
            else
                if service:setup_msg(chat, ai) then
                    local save_chat = clone_chat_without_tool_messages(chat)
                    local chat_info = {}
                    chat_info.id = datactrl.create_chat_file(service, save_chat)
                    local result = util.ubus("oasis.title", "auto_set", {id = chat_info.id}) or {}
                    chat_info.title = result.title or "--"
                    new_chat_info = jsonc.stringify(chat_info, false)
                end
            end
        else
            debug:log("oasis.log", "second called")
            if ai and not ai.tool_calls then
                debug:log("transfer-setup-msg.log", "Calling setup_msg for second call")
                debug:log("transfer-setup-msg.log", "ai.role = " .. tostring(ai.role))
                debug:log("transfer-setup-msg.log", "ai.message = " .. tostring(ai.message))
                debug:log("transfer-setup-msg.log", "ai.content = " .. tostring(ai.content))
                local setup_result = service:setup_msg(chat, ai)
                debug:log("transfer-setup-msg.log", "setup_msg returned: " .. tostring(setup_result))
                if setup_result then
                    debug:log("oasis.log", "call append_chat_data")
                    local save_chat = clone_chat_without_tool_messages(chat)
                    service:append_chat_data(save_chat)
                else
                    debug:log("transfer-setup-msg.log", "setup_msg returned false, skipping append_chat_data")
                end
            else
                debug:log("oasis.log", "skip append for tool_calls response")
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