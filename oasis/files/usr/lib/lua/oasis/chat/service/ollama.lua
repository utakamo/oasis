#!/usr/bin/env lua

local jsonc     = require("luci.jsonc")
local common    = require("oasis.common")
local uci       = require("luci.model.uci").cursor()
local util      = require("luci.util")
local datactrl  = require("oasis.chat.datactrl")
local misc      = require("oasis.chat.misc")
local debug     = require("oasis.chat.debug")

local ollama ={}
ollama.new = function()

        local obj = {}
        obj.mark = {}
        obj.recv_raw_msg = {}
        obj.recv_raw_msg.role = common.role.unknown
        obj.recv_raw_msg.message = ""
        obj.cfg = nil
        obj.format = nil
        obj.tool = false

        obj.initialize = function(self, arg, format)
            self.cfg =  datactrl.get_ai_service_cfg(arg, {format = format})
            self.format = format
        end

        local function is_model_tool_capable(model)
            local name = tostring(model or ""):lower()
            if #name == 0 then return false end
            local markers = {
                "llama3", "llama 3", -- llama3.x 系
                "qwen", "qwen2", "qwen3",
                "mistral", "mixtral",
                "deepseek",
                "phi4", "phi-4",
                "firefunction",
                "gpt-oss",
                "nemotron",
                "granite",
                "hermes",
                "smollm",
                "qwq",
                "magistral",
                "cogito",
                "command-r"
            }
            for _, m in ipairs(markers) do
                if name:find(m, 1, true) then return true end
            end
            return false
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

            -- debug:log("oasis.log", "\n--- [ollama.lua][setup_system_msg] ---");
            -- debug:log("oasis.log", "format = " .. self.format)

            -- if self.cfg.id then
            --     debug:log("oasis.log", "id = " .. self.cfg.id)
            -- end

            -- debug:dump("oasis.log", chat)

            -- debug:log("oasis.log", self.cfg.sysmsg_key)

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
                if self.format == common.ai.format.title then
                    table.insert(chat.messages, #chat.messages + 1, {
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

            debug:log("oasis.log", "\n--- [ollama.lua][setup_msg] ---")
            debug:log("ollama-setup-msg.log", "setup_msg called")
            debug:log("ollama-setup-msg.log", "speaker.role = " .. tostring(speaker and speaker.role or "nil"))
            debug:log("ollama-setup-msg.log", "speaker.message = " .. tostring(speaker and speaker.message or "nil"))
            debug:log("ollama-setup-msg.log", "speaker.content = " .. tostring(speaker and speaker.content or "nil"))
            debug:log("ollama-setup-msg.log", "speaker.tool_calls = " .. tostring(speaker and speaker.tool_calls ~= nil or "nil"))

            if (not speaker) or (not speaker.role) then
                debug:log("oasis.log", "false")
                debug:log("ollama-setup-msg.log", "No speaker or role, returning false")
                return false
            end

            chat.messages = chat.messages or {}

            local msg = { role = speaker.role }

            if speaker.role == "tool" then
                debug:log("ollama-setup-msg.log", "Processing tool message")
                if (not speaker.content) or (#tostring(speaker.content) == 0) then
                    debug:log("ollama-setup-msg.log", "No tool content, returning false")
                    return false
                end
                msg.name = speaker.name
                msg.content = speaker.content
                debug:log("ollama-setup-msg.log",
                    string.format("append TOOL msg: name=%s, len=%d",
                        tostring(msg.name or ""), (msg.content and #tostring(msg.content)) or 0))

                -- Delete entries from the messages table where the "role" is "assistant" and "tool_calls" is present.
                for i = #chat.messages, 1, -1 do
                    local data = chat.messages[i]
                    if data.role == "assistant" and data.tool_calls then
                        table.remove(chat.messages, i)
                    end
                end

                table.insert(chat.messages, msg)
                debug:log("ollama-setup-msg.log", "Tool message added, returning true")
                return true

            elseif (speaker.role == common.role.assistant) and speaker.tool_calls then
                debug:log("ollama-setup-msg.log", "Processing assistant message with tool_calls")
                -- Normalize function.arguments for Ollama: requires object (table), not JSON string
                local fixed_tool_calls = {}
                for _, tc in ipairs(speaker.tool_calls or {}) do
                    local fn = tc["function"] or {}
                    local args = fn.arguments

                    if type(args) == "string" then
                        local ok, parsed = pcall(jsonc.parse, args)
                        if ok and type(parsed) == "table" then
                            local is_array = (#parsed > 0)
                            if is_array then
                                fn.arguments = {}
                            else
                                fn.arguments = parsed
                            end
                        elseif args == "{}" then
                            fn.arguments = {}
                        else
                            fn.arguments = {}
                        end
                    elseif type(args) == "table" then
                        local is_array = (#args > 0)
                        fn.arguments = is_array and {} or args
                    else
                        fn.arguments = {}
                    end

                    table.insert(fixed_tool_calls, {
                        id = tc.id,
                        type = "function",
                        ["function"] = fn
                    })
                end
                msg.tool_calls = fixed_tool_calls
                msg.content = speaker.content or ""
                debug:log("ollama-setup-msg.log",
                    string.format("append ASSISTANT msg with tool_calls: count=%d",
                        #msg.tool_calls))

                table.insert(chat.messages, msg)
                debug:log("ollama-setup-msg.log", "Assistant message with tool_calls processed, returning true")
                return true
            else
                debug:log("ollama-setup-msg.log", "Processing regular message")
                if (not speaker.message) or (#speaker.message == 0) then
                    debug:log("ollama-setup-msg.log", "No message content, returning false")
                    return false
                end
                msg.content = speaker.message
                debug:log("ollama-setup-msg.log",
                    string.format("append %s msg: len=%d", tostring(msg.role), #msg.content))

                table.insert(chat.messages, msg)
                debug:log("ollama-setup-msg.log", "Message added to chat, returning true")
                return true
            end
        end

        obj.recv_ai_msg = function(self, chunk)

            -- Log raw response from Ollama for troubleshooting
            debug:log("ollama-ai-recv.log", tostring(chunk))

            local chunk_json = jsonc.parse(chunk)

            if (not chunk_json) or (type(chunk_json) ~= "table") then
                return "", "", self.recv_raw_msg, false
            end

            debug:log("ollama-ai-recv.log", chunk)

            -- Function Calling for Ollama (message.tool_calls[])
            if chunk_json.message and chunk_json.message.tool_calls
                and type(chunk_json.message.tool_calls) == "table"
                and #chunk_json.message.tool_calls > 0 then

                local is_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
                if is_tool then
                    local client = require("oasis.local.tool.client")
                    local message = chunk_json.message

                    local function_call = { service = "Ollama", tool_outputs = {} }
                    local first_output_str = ""

                    -- History speaker (assistant with tool_calls)
                    local speaker = { role = "assistant", tool_calls = {} }

                    for _, tc in ipairs(message.tool_calls or {}) do
                        local func = tc["function"] and tc["function"].name or ""
                        local args = {}
                        if tc["function"] and tc["function"].arguments then
                            args = tc["function"].arguments
                            if type(args) == "string" then
                                args = jsonc.parse(args) or {}
                            end
                        end

                        debug:log("function_call.log", "ollama func = " .. tostring(func))
                        local result = client.exec_server_tool(func, args)
                        debug:log("function_call_result.log", jsonc.stringify(result, true))

                        local output = jsonc.stringify(result, false)
                        table.insert(function_call.tool_outputs, {
                            output = output,
                            name = func
                        })

                        table.insert(speaker.tool_calls, {
                            id = tool_id,
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
                    return plain_text_for_console, json_text_for_webui, speaker, true
                end
            end

            if (not chunk_json.message)
                or (not chunk_json.message.role)
                or (chunk_json.message.content == nil) then
                return "", "", self.recv_raw_msg, false
            end

            self.recv_raw_msg.role = chunk_json.message.role
            self.recv_raw_msg.message = self.recv_raw_msg.message .. tostring(chunk_json.message.content)

            local plain_text_for_console = misc.markdown(self.mark, tostring(chunk_json.message.content))
            local json_text_for_webui = jsonc.stringify(chunk_json, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_raw_msg, false
            end

            return plain_text_for_console, json_text_for_webui, self.recv_raw_msg, false
        end

        obj.append_chat_data = function(self, chat)
            -- debug:log("oasis.log", "id = " .. self.cfg.id)
            -- debug:log("oasis.log", chat.messages[#chat.messages - 1].role)
            -- debug:log("oasis.log", chat.messages[#chat.messages - 1].content)
            -- debug:log("oasis.log", chat.messages[#chat.messages].role)
            -- debug:log("oasis.log", chat.messages[#chat.messages].content)
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
            local model = (self.cfg and self.cfg.model) or ""
            local supports_tool = is_model_tool_capable(model)

            -- Inject tools schema for function calling (Ollama)
            if is_use_tool and supports_tool and (self:get_format() ~= common.ai.format.title) then
                local client = require("oasis.local.tool.client")
                local schema = client.get_function_call_schema()

                user_msg["tools"] = {}
                -- Prefer non-streaming single JSON response for function calling
                user_msg["stream"] = false

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
            end

            local user_msg_json = jsonc.stringify(user_msg, false)
            user_msg_json = user_msg_json:gsub('"properties"%s*:%s*%[%]', '"properties":{}')

            debug:log("ollama-send.log", user_msg_json)

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

        return obj
end

return ollama.new()
