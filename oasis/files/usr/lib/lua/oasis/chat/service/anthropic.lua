#!/usr/bin/env lua

local jsonc     = require("luci.jsonc")
local common    = require("oasis.common")
local uci       = require("luci.model.uci").cursor()
local util      = require("luci.util")
local datactrl  = require("oasis.chat.datactrl")
local misc      = require("oasis.chat.misc")
local ous       = require("oasis.unified.chat.schema")
local debug     = require("oasis.chat.debug")
local calling   = require("oasis.chat.function.calling.anthropic")

local anthropic = {}
anthropic.new = function()

        local obj = {}
        obj.chunk_all = ""
        obj.mark = {}
        obj.recv_raw_msg = {}
        obj.recv_raw_msg.role = common.role.unknown
        obj.recv_raw_msg.message = ""
        obj.processed_tool_call_ids = {}
        obj.cfg = nil
        obj.format = nil
        obj._sysmsg_text = nil
        obj._reboot_required = false

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

        -- Convert unified schema to Anthropic Messages API body
        obj.convert_schema = function(self, chat)
            local system_buf = {}
            local messages = {}
            local pending_tool_results = {}

            local function flush_tool_results()
                if #pending_tool_results == 0 then return end
                local content = {}
                for _, tr in ipairs(pending_tool_results) do
                    local text_content = tostring(tr.content or "")
                    table.insert(content, {
                        type = "tool_result",
                        tool_use_id = tostring(tr.tool_call_id or tr.id or ""),
                        content = text_content
                    })
                end
                table.insert(messages, { role = "user", content = content })
                pending_tool_results = {}
            end

            for _, m in ipairs(chat.messages or {}) do
                local role = tostring(m.role or "")
                local text = tostring(m.content or m.message or "")
                local has_tool_calls = (m.tool_calls and type(m.tool_calls) == "table" and #m.tool_calls > 0)

                if role == common.role.system then
                    system_buf[#system_buf + 1] = text
                elseif role == common.role.user then
                    flush_tool_results()
                    table.insert(messages, { role = "user", content = { { type = "text", text = text } } })
                elseif role == common.role.assistant then
                    flush_tool_results()
                    if has_tool_calls then
                        local parts = {}
                        for _, tc in ipairs(m.tool_calls or {}) do
                            local fn = tc["function"] or {}
                            local args_tbl = ous.normalize_arguments(fn.arguments)
                            table.insert(parts, {
                                type = "tool_use",
                                id = tostring(tc.id or ""),
                                name = tostring(fn.name or ""),
                                input = args_tbl
                            })
                        end
                        table.insert(messages, { role = "assistant", content = parts })
                    else
                        table.insert(messages, { role = "assistant", content = { { type = "text", text = text } } })
                    end
                elseif role == "tool" then
                    -- accumulate to be flushed as Anthropic tool_result blocks under a user message
                    table.insert(pending_tool_results, {
                        tool_call_id = m.tool_call_id,
                        name = m.name,
                        content = text
                    })
                end
            end

            flush_tool_results()

            local system_text = table.concat(system_buf, "\n")
            if (#system_text == 0) and self._sysmsg_text and (#self._sysmsg_text > 0) then
                system_text = self._sysmsg_text
            end

            local body = {
                model = tostring(self.cfg.model or ""),
                max_tokens = tonumber(uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "max_tokens", "1024")) or 1024,
                messages = messages
            }

            -- Apply thinking/budget_tokens if enabled in UCI
            local thinking = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "thinking", "disabled") or "disabled"
            if thinking == "enabled" then
                local btk = tonumber(uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "budget_tokens", "0")) or 0
                if btk > 0 then
                    body.thinking = { type = "enabled", budget_tokens = btk }
                else
                    body.thinking = { type = "enabled" }
                end
            end

            if #system_text > 0 then
                body.system = system_text
            end

            -- Inject tools schema if local tools are enabled
            body = calling.inject_schema(self, body)

            local user_msg_json = jsonc.stringify(body, false)
            -- NOTE (why this replacement is required): Anthropic requires tool arguments ("input"/"arguments") to be a JSON object (dictionary).
            -- Some upstream paths can emit an empty array [] for these fields after serialization. To satisfy Anthropic's schema,
            -- we normalize empty arrays to empty objects here.
            user_msg_json = user_msg_json
                :gsub('"input"%s*:%s*%[%s*%]', '"input":{}')
                :gsub('"arguments"%s*:%s*%[%s*%]', '"arguments":{}')
                :gsub('"properties"%s*:%s*%[%]', '"properties":{}')
            debug:log("oasis.log", "anthropic.convert_schema", string.format("messages=%d, json_len=%d", #(messages or {}), #user_msg_json))
            debug:log("oasis.log", "anthropic.convert_schema", user_msg_json)
            return user_msg_json
        end

        obj.prepare_post_to_server = function(self, easy, callback, form, user_msg_json)
            easy:setopt_url(self.cfg.endpoint)
            easy:setopt_writefunction(callback)
            easy:setopt_httpheader({
                "Content-Type: application/json",
                "x-api-key: " .. tostring(self.cfg.api_key or ""),
                "anthropic-version: 2023-06-01"
            })
            easy:setopt_httppost(form)
            easy:setopt_postfields(user_msg_json)
        end

        obj.recv_ai_msg = function(self, chunk)
            self.chunk_all = self.chunk_all .. chunk
            local chunk_json = jsonc.parse(self.chunk_all)
            if (not chunk_json) or (type(chunk_json) ~= "table") then
                return "", "", self.recv_raw_msg, false
            end

            -- Reset per-response duplicate guard
            self.processed_tool_call_ids = {}

            debug:log("oasis.log", "anthropic.recv_ai_msg", self.chunk_all)

            -- API error handling
            if chunk_json.error and chunk_json.error.message then
                local msg = tostring(chunk_json.error.message)
                self.chunk_all = ""
                self.recv_raw_msg.role = common.role.assistant
                self.recv_raw_msg.message = msg
                local plain_text_for_console = misc.markdown(self.mark, msg)
                local response_ai_json = jsonc.stringify({ message = { role = common.role.assistant, content = msg } }, false)
                return plain_text_for_console, response_ai_json, self.recv_raw_msg, false
            end

            -- Tool call detection and processing (Anthropic tool_use)
            do
                local t_plain, t_json, t_speaker, t_used = calling.process(self, chunk_json)
                if t_plain ~= nil then
                    self.chunk_all = ""
                    return t_plain, t_json, (t_speaker or self.recv_raw_msg), t_used
                end
            end

            self.chunk_all = ""

            local text = ""
            if type(chunk_json.content) == "table" then
                for _, part in ipairs(chunk_json.content) do
                    if type(part) == "table" and part.type == "text" and part.text then
                        text = text .. tostring(part.text or "")
                    end
                end
            end

            self.recv_raw_msg.role = common.role.assistant
            self.recv_raw_msg.message = text

            local plain_text_for_console = misc.markdown(self.mark, text)
            local msg_tbl = { message = { role = common.role.assistant, content = text } }
            local response_ai_json = jsonc.stringify(msg_tbl, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_raw_msg, false
            end

            return plain_text_for_console, response_ai_json, self.recv_raw_msg, false
        end

        -- Append last two turns to storage via ubus
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

        obj.get_reboot_required = function(self)
            return self._reboot_required or false
        end

        -- Handle tool outputs: inject assistant tool_calls and tool result messages into chat
        obj.handle_tool_output = function(self, tool_info, chat)
            debug:log("oasis.log", "anthropic.handle_tool_output", "tool_info type = " .. type(tool_info))
            if not tool_info then return false end
            local info = jsonc.parse(tool_info)
            if not info or not info.tool_outputs then return false end
            if info.reboot == true then
                self._reboot_required = true
            end

            local tool_calls = {}
            for _, t in ipairs(info.tool_outputs or {}) do
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
                ous.setup_msg(self, chat, { role = common.role.assistant, tool_calls = tool_calls, content = "" })
            end

            for _, t in ipairs(info.tool_outputs or {}) do
                local content = t.output
                if type(content) ~= "string" then
                    content = jsonc.stringify(content, false)
                end
                ous.setup_msg(self, chat, {
                    role = "tool",
                    tool_call_id = t.tool_call_id or t.id,
                    name = t.name,
                    content = content
                })
            end
            return true
        end

        -- Unified hooks for tools
        obj.handle_tool_result = function(self, chat, speaker, msg)
            if (not speaker) or (speaker.role ~= "tool") then return nil end
            msg.name = speaker.name
            msg.content = speaker.content or speaker.message or ""
            msg.tool_call_id = speaker.tool_call_id
            table.insert(chat.messages, msg)
            return true
        end

        obj.handle_tool_call = function(self, chat, speaker, msg)
            if (not speaker) or (speaker.role ~= common.role.assistant) or (not speaker.tool_calls) then return nil end
            return calling.convert_tool_call(chat, speaker, msg)
        end

        return obj
end

return anthropic.new()
