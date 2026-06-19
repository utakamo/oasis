#!/usr/bin/env lua

-- local uci = require("luci.model.uci").cursor()
local curl      = require("cURL.safe")
local common    = require("oasis.common")
local console   = require("oasis.console")
local jsonc     = require("luci.jsonc")
local datactrl  = require("oasis.chat.datactrl")
local ous       = require("oasis.unified.chat.schema")
local misc      = require("oasis.chat.misc")
local debug     = require("oasis.chat.debug")
local chat_error = require("oasis.chat.error")

local M = {}
local TITLE_AUTO_SET_TIMEOUT_MS = 120000

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

    local easy_ok, easy = pcall(curl.easy)
    if (not easy_ok) or (not easy) then
        return chat_error.build(service, {
            phase = "http_request",
            kind = "connection_error",
            message = "Failed to initialize HTTP client.",
            detail = tostring(easy),
        })
    end

    local function close_easy()
        pcall(function()
            easy:close()
        end)
    end

    local prepare_ok, prepare_err = pcall(function()
        service:prepare_post_to_server(easy, callback, curl.form(), user_msg_json)
    end)

    if not prepare_ok then
        close_easy()
        return chat_error.build(service, {
            phase = "request_creation",
            kind = "request_error",
            message = "Failed to prepare AI service request.",
            detail = tostring(prepare_err),
        })
    end

    -- Send Post Request
    local perform_ok, success, perform_err = pcall(function()
        return easy:perform()
    end)

    if (not perform_ok) or (not success) then
        close_easy()
        return chat_error.build(service, {
            phase = "http_request",
            kind = "connection_error",
            message = "Failed to communicate with the AI service.",
            detail = tostring(perform_err or success),
        })
    end

    close_easy()
    return nil
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

local is_thinking_event = function(response_ai_json)
    if (not response_ai_json) or (#tostring(response_ai_json) == 0) then
        return false, nil
    end

    local tbl = jsonc.parse(response_ai_json)
    if type(tbl) == "table" and tbl.type == "thinking" then
        return true, tbl
    end

    return false, nil
end

local close_console_thinking = function(format, output_state)
    if ((format == common.ai.format.chat) or (format == common.ai.format.prompt))
        and output_state
        and output_state.thinking_started
        and (not output_state.thinking_closed) then
        console.write(common.console.color.RESET .. "\n")
        console.flush()
        output_state.thinking_closed = true
    end
end

--- Output response for console/webui based on format.
-- @param service table
-- @param format string One of common.ai.format.*
-- @param text_for_console string
-- @param response_ai_json string
-- @param tool_used boolean
-- @param output_state table
local output_response_msg = function(service, format, text_for_console, response_ai_json, tool_used, output_state)

    debug:log("oasis.log", "post_to_server", text_for_console)
    debug:log("oasis.log", "post_to_server", response_ai_json)

    local thinking_event, thinking_tbl = is_thinking_event(response_ai_json)
    if thinking_event then
        if not common.check_show_thinking_enabled(service) then
            return
        end

        if (format == common.ai.format.chat) or (format == common.ai.format.prompt) then
            local THINKING = common.console.color.THINKING
            local RESET = common.console.color.RESET
            if output_state and ((not output_state.thinking_started) or output_state.thinking_closed) then
                console.write("\n" .. THINKING .. "[thinking] ")
                output_state.thinking_started = true
                output_state.thinking_closed = false
            end
            console.write(THINKING .. tostring(thinking_tbl.content or text_for_console or "") .. RESET)
            console.flush()
        elseif format == common.ai.format.output then
            console.write(response_ai_json)
            console.flush()
        end
        return
    end

    -- Response: output console
    if (format == common.ai.format.chat) or (format == common.ai.format.prompt) then
        close_console_thinking(format, output_state)

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

    local convert_ok, usr_msg_json = pcall(function()
        return service:convert_schema(chat)
    end)

    if (not convert_ok) or (not usr_msg_json) or (#tostring(usr_msg_json) == 0) then
        return nil, recv_raw_msg, false, chat_error.build(service, {
            phase = "request_creation",
            kind = "request_error",
            message = "Failed to create AI service request body.",
            detail = tostring(usr_msg_json),
        })
    end

    -- Debug Message Json Log
    local debug_msg_json = jsonc.stringify(chat, true)
    debug:log("oasis.log", "send_user_msg", debug_msg_json)

    local format = service:get_format()
    service:init_msg_buffer()

    -- Post (Request) and Response
    local text_for_console -- text for console output
    local response_ai_json -- raw json data (Data primarily for use in the Web UI)
    local recv_error = nil
    local output_state = {}

    local post_error = M.post_to_server(service, usr_msg_json, function(chunk)
        if recv_error then
            return
        end

        local recv_ok, text, response, raw, used, err = pcall(function()
            return service:recv_ai_msg(chunk)
        end)

        if not recv_ok then
            recv_error = chat_error.build(service, {
                phase = "response_parse",
                kind = "parse_error",
                message = "Failed to process the AI service response.",
                detail = tostring(text),
            })
            return
        end

        if err then
            recv_error = err
            return
        end

        local thinking_event = is_thinking_event(response)
        if thinking_event then
            local output_ok, output_err = pcall(function()
                output_response_msg(service, format, text, response, used, output_state)
            end)

            if not output_ok then
                recv_error = chat_error.build(service, {
                    phase = "internal",
                    kind = "internal_error",
                    message = "Failed to output the AI service response.",
                    detail = tostring(output_err),
                })
            end
            return
        end

        text_for_console = text
        response_ai_json = response
        recv_raw_msg = raw
        tool_used = used

        local output_ok, output_err = pcall(function()
            output_response_msg(service, format, text_for_console, response_ai_json, tool_used, output_state)
        end)

        if not output_ok then
            recv_error = chat_error.build(service, {
                phase = "internal",
                kind = "internal_error",
                message = "Failed to output the AI service response.",
                detail = tostring(output_err),
            })
        end
    end)

    close_console_thinking(format, output_state)

    return response_ai_json, recv_raw_msg, tool_used, recv_error or post_error
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
    local tool_info, ai_response_tbl, tool_used, err = M.send_user_msg(service, chat)

    if err then
        debug:log("oasis.log", "chat_with_ai", chat_error.format(err))
        return nil, nil, false, err
    end

    debug:dump("oasis.log", ai_response_tbl)

    if tool_used then
        -- When tools are requested, return tool JSON as first value,
        -- no assistant text yet, and tool_used=true to signal caller
        return tool_info, nil, true
    end

    local new_chat_info = nil

    if (not ai_response_tbl)
        or (not ai_response_tbl.message)
        or (#tostring(ai_response_tbl.message) == 0) then
        local empty_err = chat_error.build(service, {
            phase = "response_parse",
            kind = "empty_response",
            message = "AI service returned no assistant message.",
        })
        debug:log("oasis.log", "chat_with_ai", chat_error.format(empty_err))
        return nil, nil, false, empty_err
    end

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
        else
            return nil, nil, false, chat_error.build(service, {
                phase = "response_parse",
                kind = "parse_error",
                message = "Failed to store the assistant response in chat history.",
            })
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
                    -- Title generation calls the selected AI service through oasis.title and may
                    -- exceed the default ubus timeout on slow local LLMs. Use common.ubus_call()
                    -- so this long-running ubus request has an explicit timeout.
                    local result, title_err_msg = common.ubus_call(
                        common.db.ubus.object.oasis_title,
                        common.db.ubus.method.auto_set,
                        {id = chat_info.id},
                        TITLE_AUTO_SET_TIMEOUT_MS
                    )
                    result = result or {}
                    if title_err_msg or result.status == common.status.error then
                        local title_err = chat_error.build(service, {
                            phase = "title_generation",
                            kind = "title_error",
                            message = "Chat title generation failed.",
                            provider_message = title_err_msg or result.desc,
                        })
                        chat_info.warning = title_err
                        debug:log("oasis.log", "chat_with_ai", chat_error.format(title_err))
                    end
                    chat_info.title = result.title or "--"
                    new_chat_info = jsonc.stringify(chat_info, false)
                    debug:log("oasis.log", "chat_with_ai", "new_chat_info = " .. new_chat_info)
                else
                    return nil, nil, false, chat_error.build(service, {
                        phase = "response_parse",
                        kind = "parse_error",
                        message = "Failed to store the assistant response in chat history.",
                    })
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
                    return nil, nil, false, chat_error.build(service, {
                        phase = "response_parse",
                        kind = "parse_error",
                        message = "Failed to store the assistant response in chat history.",
                    })
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

    return new_chat_info, ai_response_tbl.message, false, nil
end

return M
