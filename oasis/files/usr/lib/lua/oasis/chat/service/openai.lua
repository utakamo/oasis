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
        debug:log("oasis.log", "check_tool_call_response", "1 (invalid response: nil or not a table)")
        return false
    end

    local choices = response.choices
    if not choices or type(choices) ~= "table" or #choices == 0 then
        debug:log("oasis.log", "check_tool_call_response", "2 (invalid response: missing or empty choices array)")
        return false
    end

    local choice = choices[1]
    if not choice.message or type(choice.message) ~= "table" then
        debug:log("oasis.log", "check_tool_call_response", "3 (invalid response: missing or invalid choice.message)")
        return false
    end

    local message = choice.message

    if message.tool_calls and type(message.tool_calls) == "table" and #message.tool_calls > 0 then
        local tool = message.tool_calls[1]
        if tool["function"] and type(tool["function"]) == "table" then
            if tool["function"].name and tool["function"].arguments then
                debug:log("oasis.log", "check_tool_call_response", "4 (tool_calls present with function name and arguments detected)")
                return true
            end
        end
    end

    debug:log("oasis.log", "check_tool_call_response", "5 (no valid tool_calls found)")
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
        obj.processed_tool_call_ids = {}
        obj.cfg = nil
        obj.format = nil

        obj.initialize = function(self, arg, format)
            self.cfg = datactrl.get_ai_service_cfg(arg, {format = format})
            self.format = format
        end

        obj.init_msg_buffer = function(self)
            self.recv_raw_msg.role = common.role.unknown
            self.recv_raw_msg.message = ""
            -- Keep processed_tool_call_ids across requests to avoid duplicate tool execution
        end

        obj.set_chat_id = function(self, id)
            self.cfg.id = id
        end

        obj.setup_system_msg = function(self, chat)

            -- When role:tool is present, it indicates that results are sent to AI
            -- Here we don't include the tools field (it's okay to include it, in which case tool execution can be done for failures)
            for _, message in ipairs(chat.messages) do
                if message.role == "tool" then
                    chat.tool_choice = nil -- Remove tool_choices field assigned in previous interaction
                    chat.tools = nil -- Remove tools field assigned in previous interaction
                    return
                end
            end

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
                debug:log("oasis.log", "setup_msg",
                    string.format("append TOOL msg: id=%s, name=%s, len=%d",
                        tostring(msg.tool_call_id or ""), tostring(msg.name or ""), (msg.content and #msg.content) or 0))
            elseif speaker.role == common.role.assistant and speaker.tool_calls then
                -- assistant message that contains tool_calls
                msg.tool_calls = speaker.tool_calls
                msg.content = speaker.content or ""
                debug:log("oasis.log", "setup_msg",
                    string.format("append ASSISTANT msg with tool_calls: count=%d", #msg.tool_calls))
            else
                if not speaker.message or #speaker.message == 0 then return false end
                msg.content = speaker.message
                debug:log("oasis.log", "setup_msg",
                    string.format("append %s msg: len=%d", tostring(msg.role), #msg.content))
            end

            table.insert(chat.messages, msg)
            return true
        end

        obj._append_and_parse_chunk = function(self, chunk)
            self.chunk_all = self.chunk_all .. chunk
            local chunk_json = jsonc.parse(self.chunk_all)
            if (not chunk_json) or (type(chunk_json) ~= "table") then
                return nil
            end
            return chunk_json
        end

        obj._handle_api_error = function(self, chunk_json)
            if chunk_json and chunk_json.error then
                local error_message = chunk_json.error.message or "Unknown error"
                debug:log("oasis.log", "recv_ai_msg", "API Error: " .. error_message)
                local error_response = { message = { role = "assistant", content = error_message } }
                local plain_text_for_console = error_message
                local response_ai_json = jsonc.stringify(error_response, false)
                self.chunk_all = ""
                return plain_text_for_console, response_ai_json, self.recv_raw_msg, false
            end
            return nil
        end

        obj._choices_exist = function(self, chunk_json)
            if not chunk_json.choices or type(chunk_json.choices) ~= "table" or #chunk_json.choices == 0 then
                debug:log("oasis.log", "recv_ai_msg", "Invalid response format: missing or empty choices field")
                self.chunk_all = ""
                return false
            end
            return true
        end

        obj._get_first_message = function(self, chunk_json)
            local choice1 = chunk_json.choices and chunk_json.choices[1]
            if not choice1 or not choice1.message then
                return nil
            end
            return choice1.message
        end

        obj._process_tool_calls = function(self, message)
            if not message then return nil end
            if not check_tool_call_response({ choices = { { message = message } } }) then
                return nil
            end

            local is_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
            if not (is_tool and message and message.tool_calls) then
                return nil
            end

            debug:log("oasis.log", "recv_ai_msg", "is_tool (local_tool flag is enabled)")

            local client = require("oasis.local.tool.client")

            local function_call = { service = "OpenAI", tool_outputs = {} }
            local first_output_str = ""
            local speaker = { role = "assistant", tool_calls = {} }

            for _, tc in ipairs(message.tool_calls or {}) do
                local func = tc["function"] and tc["function"].name or ""
                local args = {}
                if tc["function"] and tc["function"].arguments then
                    args = jsonc.parse(tc["function"].arguments) or {}
                end

                debug:log("oasis.log", "recv_ai_msg", "func = " .. tostring(func) .. " (detected function name)")
                local call_id = tc.id or ""
                if self.processed_tool_call_ids[call_id] then
                    debug:log("oasis.log", "recv_ai_msg", "skip duplicate tool_call id = " .. tostring(call_id))
                else
                    self.processed_tool_call_ids[call_id] = true
                    local result = client.exec_server_tool(func, args)
                    debug:log("oasis.log", "recv_ai_msg", "tool exec result (pretty) = " .. jsonc.stringify(result, true))

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
            end

            local plain_text_for_console = first_output_str
            local response_ai_json = jsonc.stringify(function_call, false)
            debug:log("oasis.log", "recv_ai_msg", "response_ai_json = " .. response_ai_json)
            debug:log("oasis.log", "recv_ai_msg",
                string.format("return speaker(tool_calls=%d), tool_outputs=%d",
                    #speaker.tool_calls, #function_call.tool_outputs))

            self.chunk_all = ""
            return plain_text_for_console, response_ai_json, speaker, true
        end

        obj._build_text_response = function(self, message)
            self.recv_raw_msg.role = message.role
            local content = message.content or ""
            self.recv_raw_msg.message = (self.recv_raw_msg.message or "") .. content

            local reply = { message = { role = message.role, content = content } }
            local plain_text_for_console = misc.markdown(self.mark, content)
            local response_ai_json = jsonc.stringify(reply, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_ai_msg, false
            end
            return plain_text_for_console, response_ai_json, self.recv_raw_msg, false
        end

        obj.recv_ai_msg = function(self, chunk)
            -- 1) 断片を連結してJSON化（未完成なら待機）
            local chunk_json = self:_append_and_parse_chunk(chunk)
            if not chunk_json then
                return "", "", self.recv_raw_msg, false
            end

            -- 2) tool_call 重複実行ガードをメッセージ単位でリセット
            self.processed_tool_call_ids = {}

            debug:log("oasis.log", "recv_ai_msg", self.chunk_all)

            -- 3) APIエラー
            do
                local err_plain, err_json, err_raw, err_tool = self:_handle_api_error(chunk_json)
                if err_plain ~= nil then
                    return err_plain, err_json, err_raw, err_tool
                end
            end

            -- 4) choices の存在を検証（無ければここでバッファをクリアして終了）
            if not self:_choices_exist(chunk_json) then
                return "", "", self.recv_raw_msg, false
            end

            -- 5) 最初のメッセージを取得
            local message = self:_get_first_message(chunk_json)

            -- 6) ツールコール処理（該当時はここで確定返却; 内部でバッファクリア済み）
            do
                local t_plain, t_json, t_speaker, t_used = self:_process_tool_calls(message)
                if t_plain ~= nil then
                    return t_plain, t_json, t_speaker, t_used
                end
            end

            -- 7) ツールコールでない場合は、この時点でバッファをクリア
            self.chunk_all = ""

            -- 8) メッセージが無効なら終了（元実装と同等の戻り値）
            if not message then
                debug:log("oasis.log", "recv_ai_msg", "Invalid response format: missing message in choices[1]")
                return "", "", self.recv_raw_msg, false
            end

            -- 9) 通常応答の構築
            return self:_build_text_response(message)
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

            -- When role:tool is present, it indicates that results are sent to AI
            -- Here we don't include the tools field (it's okay to include it, in which case tool execution can be done for failures)
            local last = user_msg.messages and user_msg.messages[#user_msg.messages]
            if last and last.role == "tool" then
                user_msg.tool_choice = nil
                user_msg.tools = nil
                local user_msg_json = jsonc.stringify(user_msg, false)
                return user_msg_json
            end

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

            -- TODO:後で以下の処理を移動すること、専用の関数を分けても良い
            -- Inject max_tokens only when generating a title
            if self:get_format() == common.ai.format.title then
                local spath = uci:get(common.db.uci.cfg, common.db.uci.sect.role, "path")
                local conf = common.load_conf_file(spath)
                local v1 = conf and conf.title and conf.title.openai_temparature
                local v2 = conf and conf.title and conf.title.openai_max_tokens

                local n1 = tonumber(v1)
                if n1 then
                    user_msg.temparature = n1
                end

                local n2 = tonumber(v2)
                if n2 then
                    user_msg.max_tokens = n2
                end
            end

            local user_msg_json = jsonc.stringify(user_msg, false)
            user_msg_json = user_msg_json:gsub('"properties"%s*:%s*%[%]', '"properties":{}')
            return user_msg_json
        end

        obj.prepare_post_to_server = function(self, easy, callback, form, user_msg_json)

            easy:setopt_url(self.cfg.endpoint)
            easy:setopt_writefunction(callback)

            easy:setopt_httpheader({
                "Content-Type: application/json",
                "Authorization: Bearer " .. self.cfg.api_key
            })

            easy:setopt_httppost(form)
            easy:setopt_postfields(user_msg_json)
        end

        obj.handle_tool_output = function(self, tool_info, chat)
            debug:log("oasis.log", "handle_tool_output", "tool_info type = " .. type(tool_info))
            debug:log("oasis.log", "handle_tool_output", "tool_info value = " .. tostring(tool_info))
            if tool_info then
                debug:log("oasis.log", "handle_tool_output", "tool_info length = " .. tostring(#tool_info))
            end

            if not tool_info then
                debug:log("oasis.log", "handle_tool_output", "tool_info is nil, returning false")
                return false
            end

            local tool_info_tbl = jsonc.parse(tool_info)
            if tool_info_tbl then
                -- Insert assistant message with tool_calls first to satisfy OpenAI sequencing
                local tool_calls = {}

                for _, t in ipairs(tool_info_tbl.tool_outputs) do
                    local tool_id = t.tool_call_id or t.id or ""
                    local tool_name = t.name or ""
                    table.insert(tool_calls, {
                        id = tool_id,
                        type = "function",
                        ["function"] = {
                            name = tool_name,
                            arguments = "{}"
                        }
                    })
                end

                if #tool_calls > 0 then
                    debug:log(
                        "oasis.log",
                        "handle_tool_output",
                        string.format(
                            "[output] insert assistant tool_calls: count=%d",
                            #tool_calls
                        )
                    )
                    self:setup_msg(chat, { role = common.role.assistant, tool_calls = tool_calls, content = "" })
                end

                for _, t in ipairs(tool_info_tbl.tool_outputs) do

                    local content = t.output
                    if type(content) ~= "string" then
                        content = jsonc.stringify(content, false)
                    end

                    debug:log(
                        "oasis.log",
                        "handle_tool_output",
                        string.format(
                            "[output] tool msg: id=%s, name=%s, len=%d",
                            tostring(t.tool_call_id or t.id or ""),
                            tostring(t.name or ""),
                            tonumber((content and #content) or 0)
                        )
                    )

                    self:setup_msg(chat, {
                        role = "tool",
                        tool_call_id = t.tool_call_id or t.id,
                        name = t.name,
                        content = content
                    })
                end

                local chat_json = jsonc.stringify(chat, true)

                debug:log("oasis.log", "handle_tool_output", chat_json)

                return true
            end
            return false
        end

        return obj
end

return openai.new()
