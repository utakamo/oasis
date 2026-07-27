#!/usr/bin/env lua

local jsonc      = require("luci.jsonc")
local common     = require("oasis.common")
local uci        = require("luci.model.uci").cursor()
local datactrl   = require("oasis.chat.datactrl")
local misc       = require("oasis.chat.misc")
local debug      = require("oasis.chat.debug")
local chat_error = require("oasis.chat.error")

local MAX_SSE_BUFFER_BYTES = 4 * 1024 * 1024
local MAX_THINK_TAG_PROBE_BYTES = 4096
local THINK_ENVELOPES = {
    { open = "<thinking>", close = "</thinking>" },
    { open = "<think>", close = "</think>" },
}

local function new_embedded_thinking_state()
    return {
        mode = "prefix",
        pending = "",
        close_tag = nil,
        thinking = "",
        answer = "",
    }
end

local function classify_open_envelope(buffer)
    local first_non_space = tostring(buffer or ""):find("%S")
    if not first_non_space then
        return "pending", nil, nil, nil
    end

    local candidate = buffer:sub(first_non_space):lower()
    local partial = false

    for _, envelope in ipairs(THINK_ENVELOPES) do
        if candidate:sub(1, #envelope.open) == envelope.open then
            return "matched", envelope, first_non_space + #envelope.open, first_non_space
        end
        if #candidate < #envelope.open
            and envelope.open:sub(1, #candidate) == candidate then
            partial = true
        end
    end

    if partial then
        return "pending", nil, nil, first_non_space
    end

    return "none", nil, nil, first_non_space
end

local function split_close_tag_candidate(buffer, close_tag)
    local text = tostring(buffer or "")
    local lower = text:lower()
    local max_len = math.min(#lower, #close_tag - 1)

    for len = max_len, 1, -1 do
        if lower:sub(#lower - len + 1) == close_tag:sub(1, len) then
            return text:sub(1, #text - len), text:sub(#text - len + 1)
        end
    end

    return text, ""
end

local function answer_start_after_thinking_separator(buffer, first_non_space)
    if not first_non_space then
        return nil
    end

    -- Remove the provider's line-break separator, but keep indentation after
    -- its final line break because it may be meaningful Markdown content.
    for index = first_non_space - 1, 1, -1 do
        local char = buffer:sub(index, index)
        if char == "\n" or char == "\r" then
            return index + 1
        end
    end

    -- Without a line break, treat the leading horizontal whitespace itself as
    -- the provider separator.
    return first_non_space
end

local function consume_embedded_thinking(state, chunk, eof)
    local thinking_parts = {}
    local answer_parts = {}

    local function emit_thinking(text)
        text = tostring(text or "")
        if #text == 0 then
            return
        end
        state.thinking = state.thinking .. text
        thinking_parts[#thinking_parts + 1] = text
    end

    local function emit_answer(text)
        text = tostring(text or "")
        if #text == 0 then
            return
        end
        state.answer = state.answer .. text
        answer_parts[#answer_parts + 1] = text
    end

    state.pending = tostring(state.pending or "") .. tostring(chunk or "")

    while true do
        if state.mode == "prefix" then
            local status, envelope, content_start = classify_open_envelope(state.pending)

            if status == "matched" then
                state.close_tag = envelope.close
                state.pending = state.pending:sub(content_start)
                state.mode = "thinking"
            elseif status == "pending"
                and (not eof)
                and #state.pending <= MAX_THINK_TAG_PROBE_BYTES then
                break
            else
                emit_answer(state.pending)
                state.pending = ""
                state.mode = "answer"
                break
            end

        elseif state.mode == "thinking" then
            local lower = state.pending:lower()
            local close_start, close_end = lower:find(state.close_tag, 1, true)

            if close_start then
                emit_thinking(state.pending:sub(1, close_start - 1))
                state.pending = state.pending:sub(close_end + 1)
                state.close_tag = nil
                state.mode = "post_think"
            elseif eof then
                return table.concat(thinking_parts), table.concat(answer_parts),
                    "The LM Studio response contained an unterminated thinking block."
            else
                local safe, candidate = split_close_tag_candidate(state.pending, state.close_tag)
                emit_thinking(safe)
                state.pending = candidate
                break
            end

        elseif state.mode == "post_think" then
            local status, envelope, content_start, first_non_space = classify_open_envelope(state.pending)

            if status == "matched" then
                state.close_tag = envelope.close
                state.pending = state.pending:sub(content_start)
                state.mode = "thinking"
            elseif status == "pending"
                and (not eof)
                and #state.pending <= MAX_THINK_TAG_PROBE_BYTES then
                break
            else
                -- LM Studio places structural whitespace between </think> and
                -- the answer. The console output layer already inserts the
                -- requested separator, so do not persist or display it twice.
                if first_non_space then
                    local answer_start = answer_start_after_thinking_separator(
                        state.pending,
                        first_non_space
                    )
                    emit_answer(state.pending:sub(answer_start))
                    state.mode = "answer"
                end
                state.pending = ""
                break
            end

        else
            emit_answer(state.pending)
            state.pending = ""
            break
        end
    end

    return table.concat(thinking_parts), table.concat(answer_parts), nil
end

local lmstudio = {}
lmstudio.new = function()

        local obj = {}
        obj.mark = {}
        obj.recv_raw_msg = {}
        obj.recv_raw_msg.role = common.role.unknown
        obj.recv_raw_msg.message = ""
        obj.cfg = nil
        obj.format = nil
        obj._sse_buffer = ""
        obj._sse_pending_cr = false
        obj._response_mode = nil
        obj._stream_done = false
        obj._stream_record_count = 0
        obj._provider_message_delta_buffer = ""
        obj._message_delta_buffer = ""
        obj._embedded_thinking_state = new_embedded_thinking_state()
        obj._thinking_source = nil

        obj.initialize = function(self, arg, format)
            self.cfg = datactrl.get_ai_service_cfg(arg, {format = format})
            self.format = format
        end

        obj.init_msg_buffer = function(self)
            self.recv_raw_msg.role = common.role.unknown
            self.recv_raw_msg.message = ""
            self.mark = {}
            self:reset_ai_response_framer()
        end

        obj.set_chat_id = function(self, id)
            self.cfg.id = id
        end

        obj.get_config = function(self)
            return self.cfg
        end

        obj.get_format = function(self)
            return self.format
        end

        obj.get_reboot_required = function()
            return false
        end

        obj.reset_ai_response_framer = function(self)
            self._sse_buffer = ""
            self._sse_pending_cr = false
            self._response_mode = nil
            self._stream_done = false
            self._stream_record_count = 0
            self._provider_message_delta_buffer = ""
            self._message_delta_buffer = ""
            self._embedded_thinking_state = new_embedded_thinking_state()
            self._thinking_source = nil
        end

        obj.validate_ai_response_complete = function(self)
            if self._stream_record_count == 0 then
                return nil
            end

            if self._stream_done then
                return nil
            end

            return chat_error.build(self, {
                phase = "response_parse",
                kind = "parse_error",
                message = "AI response ended before LM Studio reported completion.",
                detail = string.format("records=%d chat_end=false", self._stream_record_count),
            })
        end

        obj._normalize_endpoint = function(self)
            local endpoint = tostring((self.cfg and self.cfg.endpoint) or "")

            if endpoint:match("/v1/chat/completions/?$") then
                endpoint = endpoint:gsub("/v1/chat/completions/?$", "/api/v1/chat")
            elseif endpoint:match("/v1/?$") then
                endpoint = endpoint:gsub("/v1/?$", "/api/v1/chat")
            elseif endpoint:match("/api/v1/?$") then
                endpoint = endpoint:gsub("/api/v1/?$", "/api/v1/chat")
            elseif not endpoint:match("/api/v1/chat/?$") then
                endpoint = endpoint:gsub("/+$", "") .. "/api/v1/chat"
            end

            return endpoint
        end

        obj._append_transcript_line = function(self, lines, role, content)
            local text = tostring(content or "")
            if #text == 0 then
                return
            end

            local label = "Message"
            if role == common.role.user then
                label = "User"
            elseif role == common.role.assistant then
                label = "Assistant"
            elseif role == common.role.system then
                label = "System"
            elseif role == "tool" then
                label = "Tool"
            end

            lines[#lines + 1] = label .. ": " .. text
        end

        obj._build_input_transcript = function(self, chat)
            local lines = {}
            local system_lines = {}

            for _, message in ipairs(chat.messages or {}) do
                local role = tostring(message.role or "")
                local content = tostring(message.content or message.message or "")

                if role == common.role.system then
                    if #content > 0 then
                        system_lines[#system_lines + 1] = content
                    end
                else
                    self:_append_transcript_line(lines, role, content)
                end
            end

            return table.concat(system_lines, "\n\n"), table.concat(lines, "\n\n")
        end

        obj.convert_schema = function(self, chat)
            local system_prompt, input_text = self:_build_input_transcript(chat)
            local body = {
                model = tostring(chat.model or (self.cfg and self.cfg.model) or ""),
                input = input_text,
                stream = true,
                store = false,
            }

            if #system_prompt > 0 then
                body.system_prompt = system_prompt
            end

            if self:get_format() == common.ai.format.title then
                local spath = uci:get(common.db.uci.cfg, common.db.uci.sect.role, "path")
                local conf = common.load_conf_file(spath)
                local n1 = tonumber(conf and conf.title and conf.title.openai_temperature)

                if n1 then
                    body.temperature = n1
                end
                -- Do not reuse the legacy 10-token OpenAI title limit here.
                -- LM Studio counts reasoning against max_output_tokens, so a
                -- thinking model may exhaust that budget before its message.
            end

            return jsonc.stringify(body, false)
        end

        obj.prepare_post_to_server = function(self, easy, callback, form, user_msg_json)
            local headers = {
                "Content-Type: application/json",
                "Accept: text/event-stream",
            }

            if self.cfg.api_key and #tostring(self.cfg.api_key) > 0 then
                headers[#headers + 1] = "Authorization: Bearer " .. tostring(self.cfg.api_key)
            end

            easy:setopt_url(self:_normalize_endpoint())
            easy:setopt_writefunction(callback)
            easy:setopt_httpheader(headers)
            easy:setopt_httppost(form)
            easy:setopt_postfields(user_msg_json)
        end

        obj._framing_error = function(self, message)
            return chat_error.build(self, {
                phase = "response_parse",
                kind = "parse_error",
                message = message,
                detail = string.format("max_bytes=%d", MAX_SSE_BUFFER_BYTES),
            })
        end

        obj._buffer_limit_exceeded = function(self)
            local pending_bytes = self._sse_pending_cr and 1 or 0
            return (#tostring(self._sse_buffer or "") + pending_bytes) > MAX_SSE_BUFFER_BYTES
        end

        obj._frame_sse_response = function(self, chunk, eof)
            local frames = {}
            local normalized = ""

            if self._sse_pending_cr then
                normalized = "\r"
                self._sse_pending_cr = false
            end

            normalized = normalized .. tostring(chunk or "")

            -- A curl callback may split CRLF between chunks. Preserve a final
            -- CR until the next callback so one CRLF is not mistaken for the
            -- blank line that terminates an SSE event.
            if (not eof) and normalized:sub(-1) == "\r" then
                normalized = normalized:sub(1, -2)
                self._sse_pending_cr = true
            end

            normalized = normalized:gsub("\r\n", "\n"):gsub("\r", "\n")
            self._sse_buffer = tostring(self._sse_buffer or "") .. normalized

            if self:_buffer_limit_exceeded() then
                return {}, self:_framing_error(
                    "Incomplete LM Studio SSE response exceeded the buffer limit."
                )
            end

            while true do
                local sep_start, sep_end = self._sse_buffer:find("\n\n", 1, true)
                if not sep_start then
                    break
                end

                local frame = self._sse_buffer:sub(1, sep_start - 1)
                self._sse_buffer = self._sse_buffer:sub(sep_end + 1)

                if frame:find("%S") then
                    frames[#frames + 1] = frame
                end
            end

            if eof then
                local last = tostring(self._sse_buffer or "")
                self._sse_buffer = ""
                self._sse_pending_cr = false
                if #last > 0 then
                    if last:find("%S") then
                        frames[#frames + 1] = last
                    end
                end
            end

            return frames, nil
        end

        obj.frame_ai_response = function(self, chunk, eof)
            local incoming = tostring(chunk or "")

            if self._response_mode == "json" then
                self._sse_buffer = tostring(self._sse_buffer or "") .. incoming
                if self:_buffer_limit_exceeded() then
                    return {}, self:_framing_error(
                        "Incomplete LM Studio JSON response exceeded the buffer limit."
                    )
                end

                if not eof then
                    return {}, nil
                end

                local frame = self._sse_buffer
                self._sse_buffer = ""
                if frame:find("%S") then
                    return {frame}, nil
                end
                return {}, nil
            end

            if self._response_mode == nil then
                self._sse_buffer = tostring(self._sse_buffer or "") .. incoming
                if self:_buffer_limit_exceeded() then
                    return {}, self:_framing_error(
                        "Incomplete LM Studio response exceeded the buffer limit."
                    )
                end

                local first = self._sse_buffer:match("^%s*(.)")
                if not first then
                    if eof then
                        self._sse_buffer = ""
                    end
                    return {}, nil
                end

                if first == "{" or first == "[" then
                    self._response_mode = "json"
                    if not eof then
                        return {}, nil
                    end

                    local frame = self._sse_buffer
                    self._sse_buffer = ""
                    return {frame}, nil
                end

                self._response_mode = "sse"
                local buffered = self._sse_buffer
                self._sse_buffer = ""
                return self:_frame_sse_response(buffered, eof)
            end

            return self:_frame_sse_response(incoming, eof)
        end

        obj._parse_sse_record = function(self, record)
            local event_name = nil
            local data_parts = {}
            local has_sse_field = false
            local record_text = tostring(record or "")

            for line in (record_text .. "\n"):gmatch("(.-)\n") do
                if line:sub(1, 6) == "event:" then
                    event_name = line:sub(7):gsub("^%s+", ""):gsub("%s+$", "")
                    has_sse_field = true
                elseif line:sub(1, 5) == "data:" then
                    data_parts[#data_parts + 1] = line:sub(6):gsub("^%s?", "")
                    has_sse_field = true
                end
            end

            if not has_sse_field then
                local raw_json = record_text:match("^%s*(.-)%s*$") or ""
                if #raw_json == 0 or raw_json:sub(1, 1) == ":" then
                    return { event = nil, data = nil }, nil
                end

                if raw_json:sub(1, 1) ~= "{" and raw_json:sub(1, 1) ~= "[" then
                    return nil, chat_error.build(self, {
                        phase = "response_parse",
                        kind = "parse_error",
                        message = "LM Studio response was neither SSE nor JSON.",
                    })
                end

                local raw_tbl = jsonc.parse(raw_json)
                if type(raw_tbl) ~= "table" then
                    return nil, chat_error.build(self, {
                        phase = "response_parse",
                        kind = "parse_error",
                        message = "LM Studio returned invalid JSON.",
                    })
                end

                return {
                    event = raw_tbl.type,
                    data = raw_tbl,
                }, nil
            end

            local data_str = table.concat(data_parts, "\n")
            if data_str == "[DONE]" then
                return { event = "done", data = nil }
            end

            local data_tbl = nil
            if #data_str > 0 then
                data_tbl = jsonc.parse(data_str)
                if type(data_tbl) ~= "table" then
                    return nil, chat_error.build(self, {
                        phase = "response_parse",
                        kind = "parse_error",
                        message = "LM Studio SSE event contained invalid JSON.",
                        detail = string.format("event=%s", tostring(event_name or "")),
                    })
                end
            end

            return {
                event = event_name or (type(data_tbl) == "table" and data_tbl.type) or nil,
                data = data_tbl,
            }, nil
        end

        obj._claim_thinking_source = function(self, source, content)
            if #tostring(content or "") == 0 then
                return false
            end

            if not self._thinking_source then
                self._thinking_source = source
            end

            return self._thinking_source == source
        end

        obj._include_inline_thinking = function(self)
            local format = self:get_format()
            return (format ~= common.ai.format.title)
                and (format ~= common.ai.format.rpc_output)
                and common.check_show_thinking_enabled(self)
        end

        obj._build_thinking_chunk = function(self, content, source)
            content = tostring(content or "")
            source = source or "structured"

            if not self:_claim_thinking_source(source, content) then
                return "", "", self.recv_raw_msg, false
            end

            local response_ai_json = jsonc.stringify({
                type = "thinking",
                content = content
            }, false)

            return content, response_ai_json, self.recv_raw_msg, false
        end

        obj._build_parsed_message_chunk = function(self, thinking, answer)
            thinking = tostring(thinking or "")
            answer = tostring(answer or "")

            if #answer == 0 then
                if #thinking > 0 then
                    return self:_build_thinking_chunk(thinking, "embedded")
                end
                return "", "", self.recv_raw_msg, false
            end

            local selected_thinking = ""
            if self:_claim_thinking_source("embedded", thinking) then
                selected_thinking = thinking
            end

            self._message_delta_buffer = tostring(self._message_delta_buffer or "") .. answer
            self.recv_raw_msg.role = common.role.assistant
            self.recv_raw_msg.message = self._message_delta_buffer

            local message = {
                role = common.role.assistant,
                content = answer,
            }
            if #selected_thinking > 0 and self:_include_inline_thinking() then
                message.thinking = selected_thinking
            end

            local response_ai_json = jsonc.stringify({ message = message }, false)
            local plain_text_for_console = misc.markdown(self.mark, answer)

            return tostring(plain_text_for_console or ""), response_ai_json,
                self.recv_raw_msg, false
        end

        obj._thinking_parse_error = function(self, message, detail)
            return chat_error.build(self, {
                phase = "response_parse",
                kind = "parse_error",
                message = message,
                detail = detail,
            })
        end

        obj._build_message_delta = function(self, content)
            local provider_content = tostring(content or "")
            self._provider_message_delta_buffer =
                tostring(self._provider_message_delta_buffer or "") .. provider_content

            local thinking, answer, parse_error = consume_embedded_thinking(
                self._embedded_thinking_state,
                provider_content,
                false
            )
            if parse_error then
                return nil, nil, self.recv_raw_msg, false,
                    self:_thinking_parse_error(parse_error)
            end

            return self:_build_parsed_message_chunk(thinking, answer)
        end

        obj._build_final_response = function(self, result)
            local final_message = {}

            for _, item in ipairs((result and result.output) or {}) do
                if type(item) == "table" and item.type == "message" and item.content then
                    final_message[#final_message + 1] = tostring(item.content)
                end
            end

            local text = table.concat(final_message, "")
            local streamed = tostring(self._provider_message_delta_buffer or "")

            if text:sub(1, #streamed) ~= streamed then
                return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                    phase = "response_parse",
                    kind = "parse_error",
                    message = "LM Studio final message did not match its streamed deltas.",
                    detail = string.format(
                        "streamed_bytes=%d final_bytes=%d",
                        #streamed,
                        #text
                    ),
                })
            end

            local remaining = text:sub(#streamed + 1)
            local thinking, answer, parse_error = consume_embedded_thinking(
                self._embedded_thinking_state,
                remaining,
                true
            )
            if parse_error then
                return nil, nil, self.recv_raw_msg, false,
                    self:_thinking_parse_error(parse_error)
            end

            local expected_state = new_embedded_thinking_state()
            local _, _, final_parse_error = consume_embedded_thinking(
                expected_state,
                text,
                true
            )
            if final_parse_error then
                return nil, nil, self.recv_raw_msg, false,
                    self:_thinking_parse_error(final_parse_error)
            end

            local state = self._embedded_thinking_state
            if state.thinking ~= expected_state.thinking
                or state.answer ~= expected_state.answer then
                return nil, nil, self.recv_raw_msg, false,
                    self:_thinking_parse_error(
                        "LM Studio thinking-tag parsing was inconsistent with the final response.",
                        string.format(
                            "stream_thinking_bytes=%d final_thinking_bytes=%d " ..
                                "stream_answer_bytes=%d final_answer_bytes=%d",
                            #state.thinking,
                            #expected_state.thinking,
                            #state.answer,
                            #expected_state.answer
                        )
                    )
            end

            self._provider_message_delta_buffer = text
            local plain, response, raw, used =
                self:_build_parsed_message_chunk(thinking, answer)

            self._message_delta_buffer = expected_state.answer
            self.recv_raw_msg.role = common.role.assistant
            self.recv_raw_msg.message = expected_state.answer

            return plain, response, raw, used
        end

        obj._get_api_error = function(self, event_name, data)
            if type(data) ~= "table" then
                return nil
            end

            local provider_error = data.error
            if provider_error == nil and event_name ~= "error" then
                return nil
            end

            local message = data.message or "Unknown LM Studio error"
            local detail = data.code or data.type

            if type(provider_error) == "table" then
                message = provider_error.message or message
                detail = provider_error.code or provider_error.type or detail
            elseif provider_error ~= nil then
                message = tostring(provider_error)
            end

            return chat_error.api_error(self, tostring(message), {
                detail = tostring(detail or ""),
            })
        end

        obj.recv_ai_msg = function(self, chunk)
            local parsed, parse_err = self:_parse_sse_record(chunk)
            if not parsed then
                return nil, nil, self.recv_raw_msg, false, parse_err
            end

            if self._stream_done then
                return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                    phase = "response_parse",
                    kind = "parse_error",
                    message = "LM Studio returned data after the completion event.",
                })
            end

            self._stream_record_count = self._stream_record_count + 1

            if parsed.event == "done" then
                return "", "", self.recv_raw_msg, false
            end

            local data = parsed.data or {}
            local event_name = tostring(parsed.event or data.type or "")

            debug:log("oasis.log", "lmstudio.recv_ai_msg", tostring(chunk))

            local api_error = self:_get_api_error(event_name, data)
            if api_error then
                return nil, nil, self.recv_raw_msg, false, api_error
            end

            if event_name == "reasoning.delta" then
                return self:_build_thinking_chunk(data.content or "", "structured")
            end

            if event_name == "message.delta" then
                return self:_build_message_delta(data.content or "")
            end

            if event_name == "chat.end" then
                self._stream_done = true
                return self:_build_final_response(data.result or {})
            end

            if type(data) == "table" and data.output then
                self._stream_done = true
                return self:_build_final_response(data)
            end

            return "", "", self.recv_raw_msg, false
        end

        obj.handle_tool_result = function()
            return nil
        end

        obj.handle_tool_call = function()
            return nil
        end

        obj.handle_tool_output = function()
            return false
        end

        return obj
end

return lmstudio.new()
