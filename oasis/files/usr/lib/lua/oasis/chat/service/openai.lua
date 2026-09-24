#!/usr/bin/env lua

local jsonc     = require("luci.jsonc")
local common    = require("oasis.common")
local uci       = require("luci.model.uci").cursor()
local util      = require("luci.util")
local datactrl  = require("oasis.chat.datactrl")
local misc      = require("oasis.chat.misc")
local ous       = require("oasis.unified.chat.schema")
local debug     = require("oasis.chat.debug")
local calling   = require("oasis.chat.function.calling.openai")
local chat_error = require("oasis.chat.error")

local openai = {}
openai.new = function()

        local obj = {}
        obj.chunk_all = ""
        obj.mark = {}
        obj.recv_raw_msg = {}
        obj.recv_raw_msg.role = common.role.unknown
        obj.recv_raw_msg.message = ""
        obj.processed_tool_call_ids = {}
        obj._processed_tool_results = {}
        obj.cfg = nil
        obj.format = nil
        obj._reboot_required = false
        obj._tool_side_effects_committed = false
        obj._tool_sequence_context = nil
        obj._request_tools_enabled = false
        obj._request_tool_names = {}

        obj.initialize = function(self, arg, format)
            self.cfg = datactrl.get_ai_service_cfg(arg, {format = format})
            self.format = format
            -- Service objects are singletons. Never let sequence-local policy
            -- or tool-call caches leak into the next top-level request.
            self._agent_mode = nil
            self._tool_sequence_context = nil
            self.processed_tool_call_ids = {}
            self._processed_tool_results = {}
            self._tool_side_effects_committed = false
            self._reboot_required = false
            self._request_tools_enabled = false
            self._request_tool_names = {}
        end

        obj.set_tool_sequence_context = function(self, context)
            if type(context) ~= "table" or context.active ~= true then
                self._tool_sequence_context = nil
                return true
            end

            self._tool_sequence_context = {
                active = true,
                allow_followup_tools = context.allow_followup_tools == true,
                refresh_tool_registry = context.refresh_tool_registry == true,
                remaining_ai_requests = context.remaining_ai_requests,
                remaining_tool_rounds = context.remaining_tool_rounds,
                remaining_tool_calls = context.remaining_tool_calls,
                authorize_tool_batch = context.authorize_tool_batch,
            }
            return true
        end

        obj.begin_tool_sequence = function(self)
            -- initialize() runs once for an interactive chat, not once per
            -- user turn. Reset only turn-local execution state here; reboot
            -- status remains available to the caller after the prior turn.
            self.chunk_all = ""
            self.mark = {}
            self.processed_tool_call_ids = {}
            self._processed_tool_results = {}
            self._tool_side_effects_committed = false
            self._request_tools_enabled = false
            self._request_tool_names = {}
            return true
        end

        obj._tool_sequence_allows_followup = function(self)
            local context = self._tool_sequence_context
            if type(context) == "table" and context.active == true then
                return context.allow_followup_tools == true
            end
            return self._agent_mode == true
        end

        obj._tool_sequence_blocks_current_request = function(self)
            local context = self._tool_sequence_context
            return type(context) == "table" and context.active == true
                and context.allow_followup_tools ~= true
        end

        obj.init_msg_buffer = function(self)
            self.recv_raw_msg.role = common.role.unknown
            self.recv_raw_msg.message = ""
            -- Keep processed_tool_call_ids across requests to avoid duplicate tool execution
        end

        obj.set_chat_id = function(self, id)
            self.cfg.id = id
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
                local detail = chunk_json.error.type or chunk_json.error.code
                debug:log("oasis.log", "recv_ai_msg", "API Error: " .. error_message)
                self.chunk_all = ""
                return chat_error.api_error(self, error_message, { detail = detail })
            end
            return nil
        end

        obj._choices_exist = function(self, chunk_json)
            if not chunk_json.choices or type(chunk_json.choices) ~= "table" or #chunk_json.choices == 0 then
                debug:log("oasis.log", "recv_ai_msg", "Invalid response format: missing or empty choices field")
                self.chunk_all = ""
                return false, chat_error.build(self, {
                    phase = "response_parse",
                    kind = "parse_error",
                    message = "AI response format was not recognized.",
                    provider_message = "missing or empty choices field",
                })
            end
            return true, nil
        end

        obj._get_first_message = function(self, chunk_json)
            local choice1 = chunk_json.choices and chunk_json.choices[1]
            if not choice1 or not choice1.message then
                return nil
            end
            return choice1.message
        end

        obj._process_tool_calls = function(self, message)
            return calling.process(self, message)
        end

        obj._build_text_response = function(self, message)
            self.recv_raw_msg.role = message.role
            local content = message.content or ""
            self.recv_raw_msg.message = (self.recv_raw_msg.message or "") .. content

            local reply = { message = { role = message.role, content = content } }
            local plain_text_for_console = misc.markdown(self.mark, content)
            local response_ai_json = jsonc.stringify(reply, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_raw_msg, false
            end
            return plain_text_for_console, response_ai_json, self.recv_raw_msg, false
        end

        obj.recv_ai_msg = function(self, chunk)
            -- 1) Append chunks and parse to JSON (wait if incomplete)
            local chunk_json = self:_append_and_parse_chunk(chunk)
            if not chunk_json then
                return "", "", self.recv_raw_msg, false
            end

            -- 2) Keep the duplicate-call guard for the complete top-level
            -- request. initialize() resets it before the next request.
            self.processed_tool_call_ids = self.processed_tool_call_ids or {}
            self._processed_tool_results = self._processed_tool_results or {}

            debug:log("oasis.log", "recv_ai_msg", self.chunk_all)

            -- 3) API error handling
            do
                local err = self:_handle_api_error(chunk_json)
                if err then
                    return nil, nil, self.recv_raw_msg, false, err
                end
            end

            -- 4) Verify existence of choices (clear buffer and exit if missing)
            do
                local ok, err = self:_choices_exist(chunk_json)
                if not ok then
                    return nil, nil, self.recv_raw_msg, false, err
                end
            end

            -- 5) Get the first message
            local message = self:_get_first_message(chunk_json)

            -- 6) Process tool calls (if any, return immediately; buffer cleared internally)
            do
                local t_plain, t_json, t_speaker, t_used, t_error =
                    self:_process_tool_calls(message)
                if t_error then
                    self.chunk_all = ""
                    return nil, nil, self.recv_raw_msg, false, t_error
                end
                if t_plain ~= nil then
                    return t_plain, t_json, t_speaker, t_used
                end
            end

            -- 7) If not a tool call, clear the buffer at this point
            self.chunk_all = ""

            -- 8) Exit if message is invalid (same return semantics as original)
            if not message then
                debug:log("oasis.log", "recv_ai_msg", "Invalid response format: missing message in choices[1]")
                return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                    phase = "response_parse",
                    kind = "parse_error",
                    message = "AI response format was not recognized.",
                    provider_message = "missing message in choices[1]",
                })
            end

            -- 9) Build normal text response
            return self:_build_text_response(message)
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

        obj.get_tool_side_effects_committed = function(self)
            return self._tool_side_effects_committed == true
        end

        obj.convert_schema = function(self, user_msg)

            -- When role:tool is present, it indicates that results are sent to AI
            -- Here we don't include the tools field (it's okay to include it, in which case tool execution can be done for failures)
            local last = user_msg.messages and user_msg.messages[#user_msg.messages]
            if self:_tool_sequence_blocks_current_request()
                or (last and last.role == "tool"
                    and not self:_tool_sequence_allows_followup()) then
                user_msg.tool_choice = nil
                user_msg.tools = nil
                self._request_tools_enabled = false
                self._request_tool_names = {}
                local user_msg_json = jsonc.stringify(user_msg, false)
                return user_msg_json
            end

            -- Function Calling Schema injection moved to calling module
            user_msg = calling.inject_schema(self, user_msg)

            -- TODO: Move the following logic later or extract into a dedicated function
            -- Inject title-related generation parameters
            if self:get_format() == common.ai.format.title then
                local spath = uci:get(common.db.uci.cfg, common.db.uci.sect.role, "path")
                local conf = common.load_conf_file(spath)
                local v1 = conf and conf.title and conf.title.openai_temperature
                -- Backward compatibility:
                -- prefer openai_max_completion_tokens, fallback to openai_max_tokens.
                local v2 = conf and conf.title and
                    (conf.title.openai_max_completion_tokens or conf.title.openai_max_tokens)

                local cfg_service = tostring((self.cfg and self.cfg.service) or "")
                local model_name = tostring(user_msg.model or (self.cfg and self.cfg.model) or "")
                local model_lc = model_name:lower()
                local is_openai_service = (cfg_service == common.ai.service.openai.name)
                local is_openrouter_service = (cfg_service == common.ai.service.openrouter.name)
                local is_lmstudio_service = (cfg_service == common.ai.service.lmstudio.name)
                local is_gpt5 = (model_lc:match("^gpt%-5") ~= nil)

                local n1 = tonumber(v1)
                local n2 = tonumber(v2)

                if is_gpt5 then
                    -- TODO: Revisit GPT-5 title controls after API behavior is validated.
                    -- Current workaround: omit temperature/max* for GPT-5 because
                    -- title generation has shown unstable behavior in this path.
                    user_msg.temperature = nil
                    user_msg.max_completion_tokens = nil
                    user_msg.max_tokens = nil
                else
                    if n1 then
                        user_msg.temperature = n1
                    else
                        user_msg.temperature = nil
                    end

                    if is_lmstudio_service or is_openrouter_service then
                        -- Reasoning-capable models can emit reasoning before
                        -- the title. Do not apply the legacy 10-token title
                        -- limit, which can end the response before its final
                        -- answer.
                        user_msg.max_completion_tokens = nil
                        user_msg.max_tokens = nil
                    elseif n2 then
                        if is_openai_service then
                            user_msg.max_completion_tokens = n2
                            user_msg.max_tokens = nil
                        else
                            -- Keep legacy behavior for OpenRouter compatibility.
                            user_msg.max_tokens = n2
                            user_msg.max_completion_tokens = nil
                        end
                    end
                end
            end

            local user_msg_json = jsonc.stringify(user_msg, false)
            user_msg_json = user_msg_json:gsub('"properties"%s*:%s*%[%]', '"properties":{}')
            return user_msg_json
        end

        obj.handle_tool_result = function(self, chat, speaker, msg)

            if speaker.role ~= "tool" then
                return nil
            end

            return calling.convert_tool_result(chat, speaker, msg)
        end

        obj.handle_tool_call = function(self, chat, speaker, msg)

            if (speaker.role ~= common.role.assistant) or (not speaker.tool_calls) then
                return nil
            end

            return calling.convert_tool_call(chat, speaker, msg)
        end

        obj.prepare_post_to_server = function(self, easy, callback, form, user_msg_json)

            easy:setopt_url(self.cfg.endpoint)
            easy:setopt_writefunction(callback)

            local headers = { "Content-Type: application/json" }
            local api_key = tostring((self.cfg and self.cfg.api_key) or "")
            if #api_key > 0 then
                headers[#headers + 1] = "Authorization: Bearer " .. api_key
            end
            easy:setopt_httpheader(headers)

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
                if tool_info_tbl.reboot == true then
                    self._reboot_required = true
                end
                chat.messages = chat.messages or {}
                local initial_message_count = #chat.messages
                -- Insert assistant message with tool_calls first to satisfy OpenAI sequencing
                local tool_calls = {}

                for _, t in ipairs(tool_info_tbl.tool_outputs) do
                    local tool_id = t.tool_call_id or t.id or ""
                    local tool_name = t.name or ""
                    local tool_arguments = calling.serialize_function_arguments(t.arguments)

                    table.insert(tool_calls, {
                        id = tool_id,
                        type = "function",
                        ["function"] = {
                            name = tool_name,
                            arguments = tool_arguments
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
                    local added = ous.setup_msg(self, chat, {
                        role = common.role.assistant,
                        tool_calls = tool_calls,
                        content = "",
                    })
                    if not added then
                        return false
                    end
                end

                for _, t in ipairs(tool_info_tbl.tool_outputs) do

                    local content = t.output

                    if type(content) == "table" then
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

                    local added = ous.setup_msg(self, chat, {
                        role = "tool",
                        tool_call_id = t.tool_call_id or t.id,
                        name = t.name,
                        content = content
                    })
                    if not added then
                        while #chat.messages > initial_message_count do
                            table.remove(chat.messages)
                        end
                        return false
                    end
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
