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

            local _ = self

            if (not speaker) or (not speaker.role) then
                debug:log("oasis.log", "false")
                return false
            end

            chat.messages = chat.messages or {}

            local msg = { role = speaker.role }

            if speaker.role == "tool" then
                if (not speaker.content) or (#tostring(speaker.content) == 0) then
                    return false
                end
                msg.name = speaker.name
                msg.content = speaker.content
                debug:log("ollama.setup_msg.log",
                    string.format("append TOOL msg: name=%s, len=%d",
                        tostring(msg.name or ""), (msg.content and #tostring(msg.content)) or 0))
            elseif (speaker.role == common.role.assistant) and speaker.tool_calls then
                msg.tool_calls = speaker.tool_calls
                msg.content = speaker.content or ""
                debug:log("ollama.setup_msg.log",
                    string.format("append ASSISTANT msg with tool_calls: count=%d",
                        #msg.tool_calls))
            else
                if (not speaker.message) or (#speaker.message == 0) then
                    return false
                end
                msg.content = speaker.message
                debug:log("ollama.setup_msg.log",
                    string.format("append %s msg: len=%d", tostring(msg.role), #msg.content))
            end

            table.insert(chat.messages, msg)
            return true
        end

        obj.recv_ai_msg = function(self, chunk)

            local chunk_json = jsonc.parse(chunk)

            if (not chunk_json) or (type(chunk_json) ~= "table") then
                return "", "", self.recv_raw_msg
            end

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
                    return plain_text_for_console, json_text_for_webui, speaker
                end
            end

            if (not chunk_json.message)
                or (not chunk_json.message.role)
                or (chunk_json.message.content == nil) then
                return "", "", self.recv_raw_msg
            end

            self.recv_raw_msg.role = chunk_json.message.role
            self.recv_raw_msg.message = self.recv_raw_msg.message .. tostring(chunk_json.message.content)

            local plain_text_for_console = misc.markdown(self.mark, tostring(chunk_json.message.content))
            local json_text_for_webui = jsonc.stringify(chunk_json, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_raw_msg
            end

            return plain_text_for_console, json_text_for_webui, self.recv_raw_msg
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
            return user_msg_json
        end

        return obj
end

return ollama.new()
