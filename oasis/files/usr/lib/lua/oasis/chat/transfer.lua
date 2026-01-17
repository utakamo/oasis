#!/usr/bin/env lua

-- local uci = require("luci.model.uci").cursor()
local curl      = require("cURL.safe")
local common    = require("oasis.common")
local console   = require("oasis.console")
local jsonc     = require("luci.jsonc")
local datactrl  = require("oasis.chat.datactrl")
local util      = require("luci.util")
local ous       = require("oasis.unified.chat.schema")
local misc      = require("oasis.chat.misc")
local debug     = require("oasis.chat.debug")

local M = {}

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

--- Post a JSON payload to the AI service and stream the response to callback.
-- @param service table Service object (must implement prepare_post_to_server)
-- @param user_msg_json string JSON string of request body
-- @param callback function Chunk handler for response body
function M.post_to_server(service, user_msg_json, callback)

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

--- Issue a GET request to url and stream response to callback.
-- @param url string
-- @param callback function
function M.get_to_server(url, callback)
    local easy = curl.easy()
    easy:setopt_url(url)
    easy:setopt_writefunction(callback)
    easy:perform()
    easy:close()
end

--- Output response for console/webui based on format.
-- @param format string One of common.ai.format.*
-- @param text_for_console string
-- @param response_ai_json string
-- @param tool_used boolean
local output_response_msg = function(format, text_for_console, response_ai_json, tool_used)

    debug:log("oasis.log", "post_to_server", text_for_console)
    debug:log("oasis.log", "post_to_server", response_ai_json)

    -- Response: output console
    if (format == common.ai.format.chat) or (format == common.ai.format.prompt) then

        if tool_used then
            debug:log("oasis.log", "output_response_msg", response_ai_json)
            local tool_info = jsonc.parse(response_ai_json)
            local LABEL = common.console.color.LABEL  -- bold white on blue (match Title/ID label)
            local VALUE = common.console.color.VALUE  -- bold yellow on blue (match title/id value)
            local RESET = common.console.color.RESET
            console.write(LABEL .. "Tool Used: ")
            for idx, tbl in ipairs(tool_info.tool_outputs) do

                debug:log("oasis.log", "output_response_msg", jsonc.stringify(tbl, true))

                if idx > 1 then
                    console.write(LABEL .. ", ")
                end

                if tbl.name then
                    console.write(VALUE .. tbl.name)
                end

                if tbl.output and type(tbl.output) == "string" then
                    local output = jsonc.parse(tbl.output)

                    if output.user_only then
                        console.write(RESET .. "\n\n\27[32m[User Only Message]\27[0m\n" .. output.user_only)
                    end
                end
            end

            console.write(RESET .. '\n')
            console.flush()

            if tool_info.reboot then
                misc.write_file(common.file.console.reboot_required, "reboot")
            end
            if tool_info.shutdown then
                misc.write_file(common.file.console.shutdown_required, "shutdown")
            end

        elseif (text_for_console) and (#text_for_console) > 0 then
            console.write(text_for_console)
            console.flush()
        end
        return

    -- Response: output webui
    elseif (format == common.ai.format.output) then
        if (response_ai_json) and (#response_ai_json > 0) then
            console.write(response_ai_json)
            console.flush()
        end
        return
    end

    -- Other formats: no output
end

--- Convert chat to service schema, send, and process streaming response.
-- @param service table
-- @param chat table
-- @return string response_ai_json, table recv_raw_msg, boolean tool_used
function M.send_user_msg(service, chat)

    local recv_raw_msg = ""
    local tool_used = false

    local usr_msg_json = service:convert_schema(chat)

    -- Debug Message Json Log
    local debug_msg_json = jsonc.stringify(chat, true)
    debug:log("oasis.log", "send_user_msg", debug_msg_json)

    local format = service:get_format()
    service:init_msg_buffer()

    -- Post (Request) and Response
    local text_for_console -- text for console output
    local response_ai_json -- raw json data (Data primarily for use in the Web UI)

    M.post_to_server(service, usr_msg_json, function(chunk)

        text_for_console, response_ai_json, recv_raw_msg, tool_used = service:recv_ai_msg(chunk)

        output_response_msg(format, text_for_console, response_ai_json, tool_used)
    end)

    return response_ai_json, recv_raw_msg, tool_used
end

--- High-level chat flow orchestration.
-- Returns:
--  - when tool_used: tool JSON string, nil, true
--  - otherwise: new_chat_info(string|nil), assistant_text(string), false
-- @param service table
-- @param chat table
function M.chat_with_ai(service, chat)

    debug:log("oasis.log", "chat_with_ai", "\n--- [transfer.lua][chat_with_ai] ---")

    local output_llm_model = function(format, model)

        if format ~= common.ai.format.chat then
            return
        end

        print("\n\27[34m" .. model .. "\27[0m")
    end

    local format = service:get_format()
    ous.setup_system_msg(service, chat)

    output_llm_model(format, chat.model)

    -- debug:log("oasis.log", "chat_with_ai", "dump chat data")
    -- debug:dump("oasis.log", chat)

    -- send user message and receive ai message
    local tool_info, ai_response_tbl, tool_used = M.send_user_msg(service, chat)

    debug:dump("oasis.log", ai_response_tbl)

    if tool_used then
        -- When tools are requested, return tool JSON as first value,
        -- no assistant text yet, and tool_used=true to signal caller
        return tool_info, nil, true
    end

    local new_chat_info = nil

    if format == common.ai.format.chat then
        -- debug:log("oasis.log", "chat_with_ai", "#ai_response_tbl.message = " .. tostring(#ai_response_tbl.message))
        -- debug:log("oasis.log", "chat_with_ai", "ai_response_tbl.message = " .. tostring(ai_response_tbl.message))
        -- chat mode
        if ous.setup_msg(service, chat, ai_response_tbl) then
            local cfg = service:get_config()
            if (not cfg.id) or (#cfg.id == 0) then
                -- On the first assistant text after a tool_calls turn, persist the chat
                local save_chat = clone_chat_without_tool_messages(chat)
                local chat_info = {}
                chat_info.id = datactrl.create_chat_file(service, save_chat)
                service:set_chat_id(chat_info.id)
                -- Set the title and announce to console
                datactrl.set_chat_title(service, chat_info.id)
            else
                datactrl.record_chat_data(service, chat)
            end
        end
    elseif (format == common.ai.format.output) or (format == common.ai.format.rpc_output) then

        local cfg = service:get_config()

        -- debug:dump("oasis.log", cfg)

        if (not cfg.id) or (#cfg.id == 0) then
                        debug:log("oasis.log", "chat_with_ai", "first called")
            if ai_response_tbl and ai_response_tbl.tool_calls then
                -- When the model requested tool calls, do not create file yet
                -- Defer recording until the assistant returns a text response next time
                    debug:log("oasis.log", "chat_with_ai", "tool_calls detected; defer create_chat_file")
            else
                if ous.setup_msg(service, chat, ai_response_tbl) then
                    local save_chat = clone_chat_without_tool_messages(chat)
                    local chat_info = {}
                    chat_info.id = datactrl.create_chat_file(service, save_chat)
                    local result = util.ubus("oasis.title", "auto_set", {id = chat_info.id}) or {}
                    chat_info.title = result.title or "--"
                    new_chat_info = jsonc.stringify(chat_info, false)
                    debug:log("oasis.log", "chat_with_ai", "new_chat_info = " .. new_chat_info)
                end
            end
        else
            debug:log("oasis.log", "chat_with_ai", "second called")
            if ai_response_tbl and not ai_response_tbl.tool_calls then
                debug:log("oasis.log", "transfer_setup_msg", "Calling setup_msg for second call")
                debug:log("oasis.log", "transfer_setup_msg", "ai.role = " .. tostring(ai_response_tbl.role))
                debug:log("oasis.log", "transfer_setup_msg", "ai.message = " .. tostring(ai_response_tbl.message))
                debug:log("oasis.log", "transfer_setup_msg", "ai.content = " .. tostring(ai_response_tbl.content))
                local setup_result = ous.setup_msg(service, chat, ai_response_tbl)
                debug:log("oasis.log", "transfer_setup_msg", "setup_msg returned: " .. tostring(setup_result))
                if setup_result then
                    debug:log("oasis.log", "chat_with_ai", "call append_chat_data")
                    local save_chat = clone_chat_without_tool_messages(chat)
                    ous.append_chat_data(service, save_chat)
                else
                    debug:log("oasis.log", "transfer_setup_msg", "setup_msg returned false, skipping append_chat_data")
                end
            else
                debug:log("oasis.log", "chat_with_ai", "skip append for tool_calls response")
            end
        end
    elseif format == common.ai.format.title then
    debug:log("oasis.log", "chat_with_ai", "title format")
    debug:log("oasis.log", "chat_with_ai", ai_response_tbl.message)
        ai_response_tbl.message = ai_response_tbl.message:gsub("%s+", "")
    end

    return new_chat_info, ai_response_tbl.message, false
end

return M
