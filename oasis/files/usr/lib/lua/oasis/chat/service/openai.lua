#!/usr/bin/env lua

local jsonc     = require("luci.jsonc")
local common    = require("oasis.common")
local uci       = require("luci.model.uci").cursor()
local util      = require("luci.util")
local datactrl  = require("oasis.chat.datactrl")
local misc      = require("oasis.chat.misc")
local debug     = require("oasis.chat.debug")

local check_tool_call_response = function(response)

    if not response or type(response) ~= "table" then
        debug:log("check_tool_call_response.log", "1")
        return false
    end

    local choices = response.choices
    if not choices or type(choices) ~= "table" or #choices == 0 then
        debug:log("check_tool_call_response.log", "2")
        return false
    end

    local choice = choices[1]
    if not choice.message or type(choice.message) ~= "table" then
        debug:log("check_tool_call_response.log", "3")
        return false
    end

    local message = choice.message

    if message.tool_calls and type(message.tool_calls) == "table" and #message.tool_calls > 0 then
        local tool = message.tool_calls[1]
        if tool["function"] and type(tool["function"]) == "table" then
            if tool["function"].name and tool["function"].arguments then
                debug:log("check_tool_call_response.log", "4")
                return true
            end
        end
    end

    debug:log("check_tool_call_response.log", "5")
    return false
end

local openai = {}
openai.new = function()

        local obj = {}
        obj.chunk_all = ""
        obj.mark = {}
        obj.recv_raw_msg = {}
        obj.recv_raw_msg.role = common.role.unknown
        obj.recv_raw_msg.message = ""
        obj.cfg = nil
        obj.format = nil

        obj.initialize = function(self, arg, format)
            self.cfg = datactrl.get_ai_service_cfg(arg, {format = format})
            self.format = format
        end

        obj.init_msg_buffer = function(self)
            self.recv_raw_msg.role = common.role.unknown
            self.recv_raw_msg.message = ""
        end

        obj.set_chat_id = function(self, id)
            self.cfg.id = id
        end

        obj.setup_system_msg = function(self, chat)

            local spath = uci:get(common.db.uci.cfg, common.db.uci.sect.role, "path")
            local sysmsg = common.load_conf_file(spath)

            -- Ensure sysmsg_key is valid for output/rpc_output/title formats
            do
                local default_key = uci:get(common.db.uci.cfg, common.db.uci.sect.console, "chat") or "default"
                if (not self.cfg.sysmsg_key) or (not sysmsg or not sysmsg[self.cfg.sysmsg_key]) then
                    self.cfg.sysmsg_key = default_key
                    if (not sysmsg) or (not sysmsg[self.cfg.sysmsg_key]) then
                        self.cfg.sysmsg_key = "default"
                    end
                end
            end

            -- debug:log("oasis.log", "\n--- [openai.lua][setup_system_msg] ---");
            -- debug:log("oasis.log", "format = " .. self.format)

            -- The system message (knowledge) is added to the first message in the chat.
            -- The first message is data that has not been assigned a chat ID.
            if (not self.cfg.id) or (#self.cfg.id == 0) then
                -- System message(rule or knowledge) for chat
                if (self.format == common.ai.format.chat) then
                    local target_sysmsg_key = uci:get(common.db.uci.cfg, common.db.uci.sect.console, "chat") or nil
                    if (not target_sysmsg_key) then
                        table.insert(chat.messages, 1, {
                            role = common.role.system,
                            content = string.gsub(sysmsg.default.chat, "\\n", "\n")
                        })
                    else
                        local category, target = target_sysmsg_key:match("^([^.]+)%.([^.]+)$")
                        if (category and target) and (sysmsg[category][target])then
                            table.insert(chat.messages, 1, {
                                role = common.role.system,
                                content = string.gsub(sysmsg[category][target], "\\n", "\n")
                            })
                        else
                            table.insert(chat.messages, 1, {
                                role = common.role.system,
                                content = string.gsub(sysmsg.default.chat, "\\n", "\n")
                            })
                        end
                    end
                    return
                end

                if (self.format == common.ai.format.output) or (self.format == common.ai.format.rpc_output) then
                    table.insert(chat.messages, 1, {
                        role = common.role.system,
                        content = string.gsub(sysmsg[self.cfg.sysmsg_key].chat, "\\n", "\n")
                    })
                    return
                end

                -- System message(rule or knowledge) for creating chat title
                if (self.format == common.ai.format.title) then
                    table.insert(chat.messages, 1, {
                        role = common.role.system,
                        content = string.gsub(sysmsg.general.auto_title, "\\n", "\n")
                    })
                    return
                end
            end

            if self.format == common.ai.format.prompt then
                local target_sysmsg_key = uci:get(common.db.uci.cfg, common.db.uci.sect.console, "prompt") or nil
                if (not target_sysmsg_key) then
                    table.insert(chat.messages, 1, {
                        role = common.role.system,
                        content = string.gsub(sysmsg.default.prompt, "\\n", "\n")
                    })
                else
                    local category, target = target_sysmsg_key:match("^([^.]+)%.([^.]+)$")
                    if (category and target) and (sysmsg[category][target])then
                        table.insert(chat.messages, 1, {
                            role = common.role.system,
                            content = string.gsub(sysmsg[category][target], "\\n", "\n")
                        })
                    else
                        table.insert(chat.messages, 1, {
                            role = common.role.system,
                            content = string.gsub(sysmsg.default.prompt, "\\n", "\n")
                        })
                    end
                end
                return
            end

            if self.format == common.ai.format.call then
                table.insert(chat.messages, 1, {
                    role = common.role.system,
                    content = string.gsub(sysmsg.default.call, "\\n", "\n")
                })
                return
            end
        end

        obj.setup_msg = function(self, chat, speaker)
            if not speaker or not speaker.role then return false end

            local msg = { role = speaker.role }

            if speaker.role == "tool" then
                if not speaker.tool_call_id or not speaker.content then return false end
                msg.tool_call_id = speaker.tool_call_id
                msg.name = speaker.name
                msg.content = speaker.content
                debug:log("openai.setup_msg.log",
                    string.format("append TOOL msg: id=%s, name=%s, len=%d",
                        tostring(msg.tool_call_id or ""), tostring(msg.name or ""), (msg.content and #msg.content) or 0))
            elseif speaker.role == common.role.assistant and speaker.tool_calls then
                -- assistant message that contains tool_calls
                msg.tool_calls = speaker.tool_calls
                msg.content = speaker.content or ""
                debug:log("openai.setup_msg.log",
                    string.format("append ASSISTANT msg with tool_calls: count=%d", #msg.tool_calls))
            else
                if not speaker.message or #speaker.message == 0 then return false end
                msg.content = speaker.message
                debug:log("openai.setup_msg.log",
                    string.format("append %s msg: len=%d", tostring(msg.role), #msg.content))
            end

            table.insert(chat.messages, msg)
            return true
        end

        obj.recv_ai_msg = function(self, chunk)

            -- debug:log("oasis.log", "\n--- [openai.lua][recv_ai_msg] ---")

            -- When data is received, the processing of this block will be executed.
            -- The received data is stored in a chunk.
            -- In OpenAI, the received chunk data may occasionally be missing as a JSON string.
            -- Therefore, the received data is stored in a buffer until it can be formatted into
            -- data recognizable as a JSON format.

            self.chunk_all = self.chunk_all .. chunk
            local chunk_json = jsonc.parse(self.chunk_all)

            if (not chunk_json) or (type(chunk_json) ~= "table") then
                return "", "", self.recv_raw_msg
            end

            debug:log("openai-ai-recv.log", self.chunk_all)

            -- check error message
            if chunk_json.error then
                local error_message = chunk_json.error.message or "Unknown error"

                debug:log("openai-error.log", "API Error: " .. error_message)

                local error_response = {
                    message = {
                        role = "assistant",
                        content = error_message
                    }
                }

                local plain_text_for_console = error_message
                local json_text_for_webui = jsonc.stringify(error_response, false)

                self.chunk_all = ""
                return plain_text_for_console, json_text_for_webui, self.recv_raw_msg
            end

            -- check choices field
            if not chunk_json.choices or type(chunk_json.choices) ~= "table" or #chunk_json.choices == 0 then
                debug:log("openai-error.log", "Invalid response format: missing or empty choices field")
                self.chunk_all = ""
                return "", "", self.recv_raw_msg
            end

            -- Function Calling For OpenAI
            if check_tool_call_response(chunk_json) then
                debug:log("function_call.log", "check_tool_call_response")
                local is_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
                if is_tool then
                    debug:log("function_call.log", "is_tool")
                    local client = require("oasis.local.tool.client")
                    local message = chunk_json.choices[1].message

                    -- WebUI notification payload
                    local function_call = { service = "OpenAI", tool_outputs = {} }
                    local first_output_str = ""

                    -- History speaker (assistant with tool_calls)
                    local speaker = { role = "assistant", tool_calls = {} }

                    for _, tc in ipairs(message.tool_calls or {}) do
                        local func = tc["function"] and tc["function"].name or ""
                        local args = {}
                        if tc["function"] and tc["function"].arguments then
                            args = jsonc.parse(tc["function"].arguments) or {}
                        end

                        debug:log("function_call.log", "func = " .. tostring(func))
                        local result = client.exec_server_tool(func, args)
                        debug:log("function_call_result.log", jsonc.stringify(result, true))

                        local output = jsonc.stringify(result, false)
                        table.insert(function_call.tool_outputs, {
                            tool_call_id = tc.id,
                            output = output,
                            name = func
                        })

                        table.insert(speaker.tool_calls, {
                            id = tc.id,
                            type = "function",
                            ["function"] = {
                                name = func,
                                arguments = jsonc.stringify(args, false)
                            }
                        })

                        if first_output_str == "" then first_output_str = output end
                    end

                    local plain_text_for_console = first_output_str
                    local json_text_for_webui    = jsonc.stringify(function_call, false)
                    debug:log("json_text_for_webui.log", json_text_for_webui)
                    debug:log("function_call.log",
                        string.format("return speaker(tool_calls=%d), tool_outputs=%d",
                            #speaker.tool_calls, #function_call.tool_outputs))
                    return plain_text_for_console, json_text_for_webui, speaker
                end
            end

            self.chunk_all = ""

            local plain_text_for_console
            local json_text_for_webui

            -- check choices table
            if not chunk_json.choices[1] or not chunk_json.choices[1].message then
                debug:log("openai-error.log", "Invalid response format: missing message in choices[1]")
                return "", "", self.recv_raw_msg
            end

            self.recv_raw_msg.role = chunk_json.choices[1].message.role
            self.recv_raw_msg.message = self.recv_raw_msg.message .. chunk_json.choices[1].message.content

            local reply = {}
            reply.message = {}
            reply.message.role = chunk_json.choices[1].message.role
            reply.message.content = chunk_json.choices[1].message.content

            plain_text_for_console = misc.markdown(self.mark, reply.message.content)
            json_text_for_webui = jsonc.stringify(reply, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_ai_msg
            end

            return plain_text_for_console, json_text_for_webui, self.recv_raw_msg
        end

        obj.append_chat_data = function(self, chat)
            local message = {}
            message.id = self.cfg.id
            message.role1 = chat.messages[#chat.messages - 1].role
            message.content1 = chat.messages[#chat.messages - 1].content
            message.role2 = chat.messages[#chat.messages].role
            message.content2 = chat.messages[#chat.messages].content
            util.ubus("oasis.chat", "append", message)
        end

        obj.get_config = function(self)
            return self.cfg
        end

        obj.get_format = function(self)
            return self.format
        end

        obj.convert_schema = function(self, user_msg)
            local is_use_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")

            -- Function Calling Schema
            -- Disable tool schema injection when creating a title to force plain text reply
            if is_use_tool and (self:get_format() ~= common.ai.format.title) then
                local client = require("oasis.local.tool.client")
                local schema = client.get_function_call_schema()

                user_msg["tools"] = {}

                for _, tool_def in ipairs(schema) do
                    table.insert(user_msg["tools"], {
                        type = "function",
                        ["function"] = {
                            name = tool_def.name,
                            description = tool_def.description or "",
                            parameters = tool_def.parameters
                        }
                    })
                end

                user_msg["tool_choice"] = "auto"
            end

            local user_msg_json = jsonc.stringify(user_msg, false)
            user_msg_json = user_msg_json:gsub('"properties"%s*:%s*%[%]', '"properties":{}')
            return user_msg_json
        end

        return obj
end

return openai.new()
