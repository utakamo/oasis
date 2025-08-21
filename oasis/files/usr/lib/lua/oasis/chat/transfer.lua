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

    local easy = curl.easy()

    service:prepare_post_to_server(easy, callback, curl.form(), user_msg_json)

    -- Send Post Request
    local success = easy:perform()

    if not success then
        -- TODO: WebUI Error Handling Support
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

local output_response_msg = function(format, text_for_console, text_for_webui, tool_used)

    debug:log("post_to_server.log", text_for_console)
    debug:log("post_to_server.log", text_for_webui)

    -- Response: output console
    if (format == common.ai.format.chat)
        or (format == common.ai.format.prompt) then

        if tool_used then
            local tool_info = jsonc.parse(text_for_webui)
            io.write("Tool Used: ")
            for idx, tbl in ipairs(tool_info.tool_outputs) do
                if idx > 1 then
                    io.write(", ")
                end

                if tbl.name then
                    io.write(tbl.name)
                end
            end

            io.flush()

        elseif (text_for_console) and (#text_for_console) > 0 then
            io.write(text_for_console)
            io.flush()
        end

    -- Response: output webui
    elseif (format == common.ai.format.output) then
        if (text_for_webui) and (#text_for_webui > 0) then
            io.write(text_for_webui)
            io.flush()
        end
    end
end

local send_user_msg = function(service, chat)

    local recv_raw_msg = ""
    local tool_used = false

    local usr_msg_json = service:convert_schema(chat)

    -- Debug Message Json Log
    local debug_msg_json = jsonc.stringify(chat, true)
    debug:log("debug_msg_json.log", debug_msg_json)

    local format = service:get_format()
    service:init_msg_buffer()

    -- Post (Request) and Response
    local text_for_console
    local text_for_webui

    post_to_server(service, usr_msg_json, function(chunk)

        text_for_console, text_for_webui, recv_raw_msg, tool_used = service:recv_ai_msg(chunk)

        output_response_msg(format, text_for_console, text_for_webui, tool_used)
    end)

    return text_for_webui, recv_raw_msg, tool_used
end

local chat_with_ai = function(service, chat)

    debug:log("oasis.log", "\n--- [transfer.lua][chat_with_ai] ---")

    local output_llm_model = function(format, model)

        if format ~= common.ai.format.chat then
            return
        end

        print("\n\27[34m" .. model .. "\27[0m")
    end

    local format = service:get_format()
    service:setup_system_msg(chat)
    
    output_llm_model(format, chat.model)

    debug:log("oasis.log", "dump chat data")
    debug:dump("oasis.log", chat)

    -- send user message and receive ai message
    local tool_info, ai_response_tbl, tool_used = send_user_msg(service, chat)

    debug:dump("oasis.log", ai_response_tbl)

    if tool_used then
        return tool_info, tool_used
    end

    local new_chat_info = nil

    if format == common.ai.format.chat then
        debug:log("oasis.log", "#ai_response_tbl.message = " .. #ai_response_tbl.message)
        debug:log("oasis.log", "ai_response_tbl.message = " .. ai_response_tbl.message)
        if service:setup_msg(chat, ai_response_tbl) then
            datactrl.record_chat_data(service, chat)
        end
    elseif (format == common.ai.format.output) or (format == common.ai.format.rpc_output) then

        local cfg = service:get_config()

        debug:dump("oasis.log", cfg)

        if (not cfg.id) or (#cfg.id == 0) then
            debug:log("oasis.log", "first called")
            if ai_response_tbl and ai_response_tbl.tool_calls then
                -- When the model requested tool calls, do not create file yet
                -- Defer recording until the assistant returns a text response next time
                debug:log("oasis.log", "tool_calls detected; defer create_chat_file")
            else
                if service:setup_msg(chat, ai_response_tbl) then
                    local save_chat = clone_chat_without_tool_messages(chat)
                    local chat_info = {}
                    chat_info.id = datactrl.create_chat_file(service, save_chat)
                    local result = util.ubus("oasis.title", "auto_set", {id = chat_info.id}) or {}
                    chat_info.title = result.title or "--"
                    new_chat_info = jsonc.stringify(chat_info, false)
                    debug:log("oasis.log", "new_chat_info = " .. new_chat_info)
                end
            end
        else
            debug:log("oasis.log", "second called")
            if ai_response_tbl and not ai_response_tbl.tool_calls then
                debug:log("transfer-setup-msg.log", "Calling setup_msg for second call")
                debug:log("transfer-setup-msg.log", "ai.role = " .. tostring(ai_response_tbl.role))
                debug:log("transfer-setup-msg.log", "ai.message = " .. tostring(ai_response_tbl.message))
                debug:log("transfer-setup-msg.log", "ai.content = " .. tostring(ai_response_tbl.content))
                local setup_result = service:setup_msg(chat, ai_response_tbl)
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
        debug:log("oasis.log", "title format")
        debug:log("oasis.log", ai_response_tbl.message)
        ai_response_tbl.message = ai_response_tbl.message:gsub("%s+", "")
    end

    return new_chat_info, ai_response_tbl.message, false
end

return {
    post_to_server = post_to_server,
    get_to_server = get_to_server,
    send_user_msg = send_user_msg,
    chat_with_ai = chat_with_ai,
}