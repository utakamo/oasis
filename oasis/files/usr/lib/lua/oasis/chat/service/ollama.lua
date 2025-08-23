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

                -- Title: keep only the title instruction as a single system message for Ollama
                if self.format == common.ai.format.title then
                    table.insert(chat.messages, #chat.messages + 1, {
                        role = common.role.user,
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

            debug:log("oasis.log", "setup_msg", "\n--- [ollama.lua][setup_msg] ---")
                debug:log("oasis.log", "setup_msg", "setup_msg called")
                debug:log("oasis.log", "setup_msg", "speaker.role = " .. tostring(speaker and speaker.role or "nil"))
                debug:log("oasis.log", "setup_msg", "speaker.message = " .. tostring(speaker and speaker.message or "nil"))
                debug:log("oasis.log", "setup_msg", "speaker.content = " .. tostring(speaker and speaker.content or "nil"))
                debug:log("oasis.log", "setup_msg", "speaker.tool_calls = " .. tostring(speaker and speaker.tool_calls ~= nil or "nil"))

            if (not speaker) or (not speaker.role) then
                debug:log("oasis.log", "setup_msg", "false")
                    debug:log("oasis.log", "setup_msg", "No speaker or role, returning false")
                return false
            end

            chat.messages = chat.messages or {}

            local msg = { role = speaker.role }

            if speaker.role == "tool" then
                debug:log("oasis.log", "setup_msg", "Processing tool message")
                if (not speaker.content) or (#tostring(speaker.content) == 0) then
                    debug:log("oasis.log", "setup_msg", "No tool content, returning false")
                    return false
                end
                msg.name = speaker.name
                msg.content = speaker.content
                debug:log("oasis.log", "setup_msg",
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
                    debug:log("oasis.log", "setup_msg", "Tool message added, returning true")
                return true

            elseif (speaker.role == common.role.assistant) and speaker.tool_calls then
                debug:log("oasis.log", "setup_msg", "Processing assistant message with tool_calls")
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
                debug:log("oasis.log", "setup_msg",
                    string.format("append ASSISTANT msg with tool_calls: count=%d",
                        #msg.tool_calls))

                table.insert(chat.messages, msg)
                debug:log("oasis.log", "setup_msg", "Assistant message with tool_calls processed, returning true")
                return true
            else
                debug:log("oasis.log", "setup_msg", "Processing regular message")
                if (not speaker.message) or (#speaker.message == 0) then
                    debug:log("oasis.log", "setup_msg", "No message content, returning false")
                    return false
                end
                msg.content = speaker.message
                debug:log("oasis.log", "setup_msg",
                    string.format("append %s msg: len=%d", tostring(msg.role), #msg.content))

                table.insert(chat.messages, msg)
                    debug:log("oasis.log", "setup_msg", "Message added to chat, returning true")
                return true
            end
        end

        obj.recv_ai_msg = function(self, chunk)

            -- Log raw response from Ollama for troubleshooting
                debug:log("oasis.log", "recv_ai_msg", tostring(chunk))

            local chunk_json = jsonc.parse(chunk)

            if (not chunk_json) or (type(chunk_json) ~= "table") then
                return "", "", self.recv_raw_msg, false
            end

                debug:log("oasis.log", "recv_ai_msg", chunk)

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

                            debug:log("oasis.log", "recv_ai_msg", "ollama func = " .. tostring(func))
                        local result = client.exec_server_tool(func, args)
                            debug:log("oasis.log", "recv_ai_msg", jsonc.stringify(result, true))

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
                    local response_ai_json    = jsonc.stringify(function_call, false)
                    debug:log("oasis.log", "recv_ai_msg", response_ai_json)
                    return plain_text_for_console, response_ai_json, speaker, true
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
            local response_ai_json = jsonc.stringify(chunk_json, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_raw_msg, false
            end

            return plain_text_for_console, response_ai_json, self.recv_raw_msg, false
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

            -- When role:tool is present, it indicates that results are sent to AI
            -- Here we don't include the tools field (it's okay to include it, in which case tool execution can be done for failures)
            local last = user_msg.messages and user_msg.messages[#user_msg.messages]
            if last and last.role == "tool" then
                user_msg.tool_choice = nil
                user_msg.tools = nil
                local user_msg_json = jsonc.stringify(user_msg, false)
                return user_msg_json
            end

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

            debug:log("oasis.log", "prepare_post_to_server", user_msg_json)

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
                -- Insert assistant message with tool_calls first to satisfy Ollama sequencing
                local tool_calls = {}

                for _, t in ipairs(tool_info_tbl.tool_outputs) do
                    local tool_id = t.id or ""
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
                            tostring(t.id or ""),
                            tostring(t.name or ""),
                            tonumber((content and #content) or 0)
                        )
                    )

                    self:setup_msg(chat, {
                        role = "tool",
                        tool_call_id = t.id,
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

return ollama.new()
