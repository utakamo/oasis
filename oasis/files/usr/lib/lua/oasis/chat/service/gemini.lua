#!/usr/bin/env lua

local jsonc     = require("luci.jsonc")
local common    = require("oasis.common")
local uci       = require("luci.model.uci").cursor()
local util      = require("luci.util")
local datactrl  = require("oasis.chat.datactrl")
local misc      = require("oasis.chat.misc")
local debug     = require("oasis.chat.debug")

local gemini ={}
gemini.new = function()

        local obj = {}
        obj.chunk_all = ""
        obj.mark = {}
        obj.recv_raw_msg = {}
        obj.recv_raw_msg.role = common.role.unknown
        obj.recv_raw_msg.message = ""
        obj.cfg = nil
        obj._format = nil
        obj._sysmsg_text = nil

        obj.initialize = function(self, arg, format)
            self.cfg = datactrl.get_ai_service_cfg(arg, {format = format})
            self._format = format
            if (not self.cfg.model) or (#tostring(self.cfg.model) == 0) then
                self.cfg.model = "gemini-2.0-flash"
            end
            debug:log("oasis.log", "gemini.initialize",
                string.format("format=%s, model=%s, endpoint=%s",
                    tostring(format), tostring(self.cfg.model), tostring(self.cfg.endpoint)))
        end

        obj.init_msg_buffer = function(self)
            self.recv_raw_msg.role = common.role.unknown
            self.recv_raw_msg.message = ""
            debug:log("oasis.log", "gemini.init_msg_buffer", "buffer cleared")
        end

        obj.set_chat_id = function(self, id)
            self.cfg.id = id
            debug:log("oasis.log", "gemini.set_chat_id", "id=" .. tostring(id))
        end

        obj.setup_msg = function(_, chat, speaker)
            if not speaker or not speaker.role then return false end
            if not speaker.message or #speaker.message == 0 then return false end
            chat.messages = chat.messages or {}
            table.insert(chat.messages, { role = speaker.role, content = speaker.message, name = speaker.name })
            debug:log(
                "oasis.log",
                "gemini.setup_msg",
                string.format(
                    "role=%s, name=%s, len=%d",
                    tostring(speaker.role),
                    tostring(speaker.name or ""),
                    #speaker.message
                )
            )
            return true
        end

        obj.setup_system_msg = function(self, _)
            local spath = uci:get(common.db.uci.cfg, common.db.uci.sect.role, "path")
            local sysmsg = common.load_conf_file(spath)

            -- Always prepare title instruction for title generation
            if (self._format == common.ai.format.title) then
                self._sysmsg_text = string.gsub(sysmsg.general.auto_title, "\\n", "\n")
                debug:log("oasis.log", "gemini.setup_system_msg",
                    string.format("format=%s, sysmsg_len=%d",
                        tostring(self._format), (self._sysmsg_text and #self._sysmsg_text or 0)))
                return
            end

            if (not self.cfg.id) or (#self.cfg.id == 0) then
                if (self._format == common.ai.format.chat) then
                    self._sysmsg_text = string.gsub(sysmsg.default.chat, "\\n", "\n")
                elseif (self._format == common.ai.format.output) or (self._format == common.ai.format.rpc_output) then
                    self._sysmsg_text = string.gsub((sysmsg.default.output or sysmsg.default.chat), "\\n", "\n")
                elseif (self._format == common.ai.format.prompt) then
                    self._sysmsg_text = string.gsub(sysmsg.default.prompt, "\\n", "\n")
                elseif (self._format == common.ai.format.call) then
                    self._sysmsg_text = string.gsub((sysmsg.default.call or sysmsg.default.chat), "\\n", "\n")
                end
                debug:log("oasis.log", "gemini.setup_system_msg",
                    string.format("format=%s, sysmsg_len=%d",
                        tostring(self._format), (self._sysmsg_text and #self._sysmsg_text or 0)))
            end
        end

        obj.convert_schema = function(self, chat)
            local contents = {}

            local messages = chat.messages or {}
            debug:log("oasis.log", "gemini.convert_schema", "messages_count=" .. tostring(#messages))
            for _, m in ipairs(messages) do
                local role = tostring(m.role or "")
                local text = tostring(m.content or m.message or "")
                if #text > 0 then
                    if role == common.role.user then
                        table.insert(contents, { role = "user", parts = { { text = text } } })
                    elseif role == common.role.assistant then
                        table.insert(contents, { role = "model", parts = { { text = text } } })
                    elseif role == "tool" then
                        -- map tool result to Gemini functionResponse
                        local resp
                        local ok, parsed = pcall(jsonc.parse, text)
                        if ok and parsed then
                            resp = parsed
                        else
                            resp = text
                        end
                        debug:log(
                            "oasis.log",
                            "gemini.convert_schema",
                            string.format(
                                "append functionResponse placeholder: name=%s, len=%d",
                                tostring(m.name or ""),
                                (type(text) == "string" and #text) or 0
                            )
                        )
                        local fname = tostring(m.name or "")
                        if fname == "" then
                            debug:log("oasis.log", "gemini.convert_schema", "skip functionResponse: empty name")
                        else
                            table.insert(contents, {
                                role = "user",
                                parts = { { functionResponse = { name = fname, response = resp } } }
                            })
                        end
                    end
                end
            end

            if #contents == 0 then
                table.insert(contents, { parts = { { text = "" } } })
            end

            local body = { contents = contents }

            -- Inject tool schema (Gemini functionDeclarations)
            do
                local is_use_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
                if is_use_tool and (self._format ~= common.ai.format.title) then
                    local client = require("oasis.local.tool.client")
                    local schema = client.get_function_call_schema()
                    local fdecl = {}
                    for _, tool_def in ipairs(schema or {}) do
                        -- sanitize parameters for Gemini (remove additionalProperties, ensure properties is an object)
                        local params = tool_def.parameters or {}
                        local sanitized = {
                            type = params.type or "object",
                            properties = params.properties or {},
                            required = params.required or {}
                        }
                        table.insert(fdecl, {
                            name = tool_def.name,
                            description = tool_def.description or "",
                            parameters = sanitized
                        })
                    end
                    if #fdecl > 0 then
                        -- Gemini expects an array of tools, each with functionDeclarations
                        body.tools = { { functionDeclarations = fdecl } }
                        debug:log(
                            "oasis.log",
                            "gemini.convert_schema",
                            string.format(
                                "inject functionDeclarations: count=%d",
                                #fdecl
                            )
                        )
                    else
                        debug:log(
                            "oasis.log",
                            "gemini.convert_schema",
                            "no functionDeclarations available"
                        )
                    end
                else
                    debug:log(
                        "oasis.log",
                        "gemini.convert_schema",
                        "local_tool disabled or title format; skip tool schema"
                    )
                end
            end

            if self._sysmsg_text and (#self._sysmsg_text > 0) then
                body.systemInstruction = {
                    parts = { { text = self._sysmsg_text } }
                }
                debug:log("oasis.log", "gemini.convert_schema", "systemInstruction attached")
            end

            local user_msg_json = jsonc.stringify(body, false)
            -- Ensure empty properties are objects, not arrays (jsonc may encode empty Lua tables as [])
            user_msg_json = user_msg_json:gsub('"properties"%s*:%s*%[%]', '"properties":{}')
            debug:log("oasis.log", "gemini.convert_schema",
                string.format("contents=%d, json_len=%d", #contents, #user_msg_json))
            return user_msg_json
        end

        obj.prepare_post_to_server = function(self, easy, callback, form, user_msg_json)
            local base = tostring(self.cfg.endpoint or "")
            if #base == 0 then
                base = "https://generativelanguage.googleapis.com"
            end
            local model = tostring(self.cfg.model or "gemini-2.0-flash")
            local url = string.format("%s/v1beta/models/%s:generateContent", base, model)

            easy:setopt_url(url)
            easy:setopt_writefunction(callback)
            easy:setopt_httpheader({
                "Content-Type: application/json",
                "X-Goog-Api-Key: " .. tostring(self.cfg.api_key or "")
            })
            easy:setopt_httppost(form)
            easy:setopt_postfields(user_msg_json)
            debug:log("oasis.log", "gemini.prepare_post_to_server",
                string.format("url=%s, body_len=%d", url, #tostring(user_msg_json)))
        end

        obj.recv_ai_msg = function(self, chunk)
            local clen = (chunk and #chunk) or 0
            debug:log("oasis.log", "gemini.recv_ai_msg", "chunk_len=" .. tostring(clen))
            self.chunk_all = self.chunk_all .. chunk
            local chunk_json = jsonc.parse(self.chunk_all)

            if (not chunk_json) or (type(chunk_json) ~= "table") then
                debug:log("oasis.log", "gemini.recv_ai_msg", "incomplete json; waiting more chunks")
                return "", "", self.recv_raw_msg, false
            end

            self.chunk_all = ""

            if chunk_json.error and (chunk_json.error.message) then
                local msg = tostring(chunk_json.error.message)
                debug:log("oasis.log", "gemini.recv_ai_msg", "api_error=" .. msg)
                self.recv_raw_msg.role = common.role.assistant
                self.recv_raw_msg.message = msg
                local plain_text_for_console = misc.markdown(self.mark, msg)
                local response_ai_json = jsonc.stringify({
                    message = {
                        role = common.role.assistant,
                        content = msg
                    }
                }, false)
                return plain_text_for_console, response_ai_json, self.recv_raw_msg, false
            end

            -- Detect functionCall in candidates → execute local tool and return tool_used
            do
                local c = (chunk_json.candidates and chunk_json.candidates[1]) or nil
                local parts = c and c.content and c.content.parts or nil
                if parts and type(parts) == "table" then
                    for _, p in ipairs(parts) do
                        if type(p) == "table" and p.functionCall then
                            local f = p.functionCall
                            local fname = tostring(f.name or "")
                            local fargs = f.args
                            if type(fargs) == "string" then
                                local ok, parsed = pcall(jsonc.parse, fargs)
                                if ok and parsed then fargs = parsed end
                            end
                            if type(fargs) ~= "table" then fargs = {} end

                            debug:log("oasis.log", "gemini.recv_ai_msg",
                                string.format("functionCall detected: name=%s", fname))
                            debug:log(
                                "oasis.log",
                                "gemini.recv_ai_msg",
                                string.format(
                                    "args_keys=%d",
                                    (function(tbl) local n=0; for _ in pairs(tbl) do n=n+1 end; return n end)(fargs)
                                )
                            )

                            local client = require("oasis.local.tool.client")
                            local result = client.exec_server_tool(fname, fargs)
                            local output = jsonc.stringify(result, false)
                            debug:log(
                                "oasis.log",
                                "gemini.recv_ai_msg",
                                string.format("tool result len=%d", (output and #output) or 0)
                            )

                            local function_call = {
                                service = "Gemini",
                                tool_outputs = {
                                    { name = fname, output = output }
                                }
                            }

                            local first_output_str = output or ""
                            local response_ai_json = jsonc.stringify(function_call, false)

                            return first_output_str, response_ai_json, self.recv_raw_msg, true
                        end
                    end
                end
            end

            local text = ""
            if chunk_json.candidates
                and type(chunk_json.candidates) == "table"
                and chunk_json.candidates[1]
                and chunk_json.candidates[1].content
                and chunk_json.candidates[1].content.parts
                and chunk_json.candidates[1].content.parts[1]
                and chunk_json.candidates[1].content.parts[1].text then
                text = tostring(chunk_json.candidates[1].content.parts[1].text or "")
            end

            self.recv_raw_msg.role = common.role.assistant
            self.recv_raw_msg.message = text
            debug:log("oasis.log", "gemini.recv_ai_msg", "text_len=" .. tostring(#text))

            local plain_text_for_console = misc.markdown(self.mark, text)
            local msg_tbl = {
                message = {
                    role = common.role.assistant,
                    content = text
                }
            }
            local response_ai_json = jsonc.stringify(msg_tbl, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_raw_msg, false
            end

            return plain_text_for_console, response_ai_json, self.recv_raw_msg, false
        end

        -- Handle tool outputs by appending functionResponse messages for Gemini
        obj.handle_tool_output = function(self, tool_info, chat)
            debug:log("oasis.log", "gemini.handle_tool_output", "tool_info type = " .. type(tool_info))
            if not tool_info then return false end
            local info = jsonc.parse(tool_info)
            if not info or not info.tool_outputs then return false end

            local count = 0
            for _, t in ipairs(info.tool_outputs or {}) do
                local content = t.output
                if type(content) ~= "string" then
                    content = jsonc.stringify(content, false)
                end
                self:setup_msg(chat, {
                    role = "tool",
                    message = content,
                    name = t.name
                })
                count = count + 1
            end
            debug:log(
                "oasis.log",
                "gemini.handle_tool_output",
                string.format("appended functionResponse messages: count=%d", count)
            )
            return true
        end

        obj.append_chat_data = function(self, chat)
            local message = {}
            message.id = self.cfg.id
            message.role1 = chat.messages[#chat.messages - 1].role
            message.content1 = chat.messages[#chat.messages - 1].content
            message.role2 = chat.messages[#chat.messages].role
            message.content2 = chat.messages[#chat.messages].content
            util.ubus("oasis.chat", "append", message)
            debug:log("oasis.log", "gemini.append_chat_data",
                string.format("id=%s, r1=%s, r2=%s",
                    tostring(self.cfg.id), tostring(message.role1), tostring(message.role2)))
        end

        obj.get_config = function(self)
            return self.cfg
        end

        obj.get_format = function(self)
            return self._format
        end

        return obj
end

return gemini.new()
