#!/usr/bin/env lua

local jsonc      = require("luci.jsonc")
local common     = require("oasis.common")
local datactrl   = require("oasis.chat.datactrl")
local misc       = require("oasis.chat.misc")
local debug      = require("oasis.chat.debug")
local ous        = require("oasis.unified.chat.schema")
local calling    = require("oasis.chat.function.calling.openai_responses")
local chat_error = require("oasis.chat.error")

local MAX_SSE_BUFFER_BYTES = 4 * 1024 * 1024

local function non_empty(value)
    value = tostring(value or "")
    if #value > 0 then
        return value
    end
    return nil
end

local function copy_array(source)
    local result = {}
    for _, value in ipairs(source or {}) do
        result[#result + 1] = value
    end
    return result
end

local openai_responses = {}
openai_responses.new = function()
    local obj = {}

    obj.cfg = nil
    obj.format = nil
    obj.mark = {}
    obj.recv_raw_msg = { role = common.role.unknown, message = "" }
    obj.processed_tool_call_ids = {}
    obj._processed_tool_results = {}
    obj._reboot_required = false
    obj._tool_side_effects_committed = false
    obj._pending_provider_items = nil
    obj._completed_response_output = nil
    obj._completed_tool_message = nil
    obj._request_tools_enabled = false

    obj.initialize = function(self, arg, format)
        self.cfg = datactrl.get_ai_service_cfg(arg, { format = format })
        self.format = format
        -- This module is a singleton. A new command/request context must not
        -- inherit transient provider state or a previous agent-mode marker.
        self._agent_mode = nil
        self.processed_tool_call_ids = {}
        self._processed_tool_results = {}
        self._tool_side_effects_committed = false
        self._reboot_required = false
        self._request_tools_enabled = false
        self._request_tool_names = {}
        self:_reset_stream_state(true)
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

    obj.get_reboot_required = function(self)
        return self._reboot_required or false
    end

    obj.get_tool_side_effects_committed = function(self)
        return self._tool_side_effects_committed == true
    end

    obj._reset_stream_state = function(self, clear_provider_state)
        self._sse_buffer = ""
        self._sse_pending_cr = false
        self._response_mode = nil
        self._response_done = false
        self._terminal_event = nil
        self._stream_record_count = 0
        self._answer_delta_buffer = ""
        self._summary_delta_buffer = ""
        self._output_text_parts = {}
        self._refusal_parts = {}
        self._summary_text_parts = {}
        self._function_calls_by_item = {}
        self._function_call_order = {}
        self._function_call_ids = {}
        self._tool_calls_finalized = false
        self._completed_response_output = nil
        self._completed_tool_message = nil
        if clear_provider_state then
            self._pending_provider_items = nil
        end
    end

    obj.init_msg_buffer = function(self)
        self.recv_raw_msg.role = common.role.unknown
        self.recv_raw_msg.message = ""
        self.mark = {}
        -- convert_schema() runs before this hook. Do not discard provider items
        -- that were prepared for an immediate function-call follow-up.
        if type(self._pending_provider_items) ~= "table"
            or #self._pending_provider_items == 0 then
            self.processed_tool_call_ids = {}
            self._processed_tool_results = {}
            self._tool_side_effects_committed = false
        end
        self:_reset_stream_state(false)
    end

    obj.reset_ai_response_framer = function(self)
        self:_reset_stream_state(true)
    end

    obj._summary_requested = function(self)
        local format = self:get_format()
        return common.check_show_thinking_enabled(self)
            and (format == common.ai.format.chat
                or format == common.ai.format.prompt
                or format == common.ai.format.output)
    end

    obj._normalize_endpoint = function(self)
        -- The configuration layer selects the Responses endpoint. Custom URLs
        -- are literal and may use a gateway-specific path, so do not rewrite it.
        return tostring((self.cfg and self.cfg.endpoint) or "")
    end

    obj._convert_messages = function(self, chat, use_provider_items)
        local input = {}

        for _, message in ipairs(chat.messages or {}) do
            local role = tostring(message.role or "")
            local has_tool_calls = type(message.tool_calls) == "table"
                and #message.tool_calls > 0

            if role == "tool" then
                if not use_provider_items then
                    input[#input + 1] = {
                        type = "function_call_output",
                        call_id = tostring(message.tool_call_id or ""),
                        output = tostring(message.content or ""),
                    }
                end
            elseif role == common.role.assistant and has_tool_calls then
                if not use_provider_items then
                    for _, tool_call in ipairs(message.tool_calls) do
                        local fn = tool_call["function"] or {}
                        local arguments = fn.arguments
                        if type(arguments) == "table" then
                            arguments = jsonc.stringify(arguments, false)
                        end
                        input[#input + 1] = {
                            type = "function_call",
                            call_id = tostring(tool_call.id or ""),
                            name = tostring(fn.name or ""),
                            arguments = tostring(arguments or "{}"),
                        }
                    end
                end
            elseif role == common.role.system or role == common.role.user
                or role == common.role.assistant then
                input[#input + 1] = {
                    role = role,
                    content = tostring(message.content or message.message or ""),
                }
            end
        end

        if use_provider_items then
            for _, item in ipairs(self._pending_provider_items or {}) do
                input[#input + 1] = item
            end
        end

        return input
    end

    obj.convert_schema = function(self, chat)
        local use_provider_items = type(self._pending_provider_items) == "table"
            and #self._pending_provider_items > 0
        local input = self:_convert_messages(chat, use_provider_items)
        local body = {
            model = tostring(chat.model or (self.cfg and self.cfg.model) or ""),
            input = input,
            stream = true,
            store = false,
        }

        if self:_summary_requested() then
            body.reasoning = { summary = "auto" }
        end

        local messages = chat.messages or {}
        local last = messages[#messages]
        local disable_tools = last and last.role == "tool" and not self._agent_mode
        body = calling.inject_schema(self, body, disable_tools)

        local encoded = jsonc.stringify(body, false)
        encoded = encoded
            :gsub('"arguments"%s*:%s*%[%s*%]', '"arguments":{}')
            :gsub('"parameters"%s*:%s*%[%s*%]', '"parameters":{}')
            :gsub('"properties"%s*:%s*%[%s*%]', '"properties":{}')
        debug:log("oasis.log", "openai_responses.convert_schema",
            string.format("input_items=%d tools=%s summary=%s",
                #input, tostring(self._request_tools_enabled),
                tostring(body.reasoning ~= nil)))
        return encoded
    end

    obj.prepare_post_to_server = function(self, easy, callback, form, user_msg_json)
        easy:setopt_url(self:_normalize_endpoint())
        easy:setopt_writefunction(callback)
        easy:setopt_httpheader({
            "Content-Type: application/json",
            "Accept: text/event-stream",
            "Authorization: Bearer " .. tostring((self.cfg and self.cfg.api_key) or ""),
        })
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
        local pending = self._sse_pending_cr and 1 or 0
        return #tostring(self._sse_buffer or "") + pending > MAX_SSE_BUFFER_BYTES
    end

    obj._frame_sse = function(self, chunk, eof)
        local frames = {}
        local normalized = ""
        if self._sse_pending_cr then
            normalized = "\r"
            self._sse_pending_cr = false
        end
        normalized = normalized .. tostring(chunk or "")

        if not eof and normalized:sub(-1) == "\r" then
            normalized = normalized:sub(1, -2)
            self._sse_pending_cr = true
        end
        normalized = normalized:gsub("\r\n", "\n"):gsub("\r", "\n")
        self._sse_buffer = tostring(self._sse_buffer or "") .. normalized

        if self:_buffer_limit_exceeded() then
            return {}, self:_framing_error(
                "Incomplete OpenAI SSE response exceeded the buffer limit.")
        end

        while true do
            local first, last = self._sse_buffer:find("\n\n", 1, true)
            if not first then
                break
            end
            local frame = self._sse_buffer:sub(1, first - 1)
            self._sse_buffer = self._sse_buffer:sub(last + 1)
            if frame:find("%S") then
                frames[#frames + 1] = frame
            end
        end

        if eof then
            local remaining = tostring(self._sse_buffer or "")
            self._sse_buffer = ""
            self._sse_pending_cr = false
            if remaining:find("%S") then
                frames[#frames + 1] = remaining
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
                    "Incomplete OpenAI JSON response exceeded the buffer limit.")
            end
            if not eof then
                return {}, nil
            end
            local frame = self._sse_buffer
            self._sse_buffer = ""
            return frame:find("%S") and { frame } or {}, nil
        end

        if self._response_mode == nil then
            self._sse_buffer = tostring(self._sse_buffer or "") .. incoming
            if self:_buffer_limit_exceeded() then
                return {}, self:_framing_error(
                    "Incomplete OpenAI response exceeded the buffer limit.")
            end
            local first = self._sse_buffer:match("^%s*(.)")
            if not first then
                if eof then self._sse_buffer = "" end
                return {}, nil
            end
            if first == "{" or first == "[" then
                self._response_mode = "json"
                if not eof then return {}, nil end
                local frame = self._sse_buffer
                self._sse_buffer = ""
                return { frame }, nil
            end
            self._response_mode = "sse"
            local buffered = self._sse_buffer
            self._sse_buffer = ""
            return self:_frame_sse(buffered, eof)
        end

        return self:_frame_sse(incoming, eof)
    end

    obj._parse_record = function(self, record)
        local record_text = tostring(record or "")
        local event_name = nil
        local data_parts = {}
        local has_field = false

        for line in (record_text .. "\n"):gmatch("(.-)\n") do
            if line:sub(1, 6) == "event:" then
                event_name = line:sub(7):gsub("^%s+", ""):gsub("%s+$", "")
                has_field = true
            elseif line:sub(1, 5) == "data:" then
                data_parts[#data_parts + 1] = line:sub(6):gsub("^%s?", "")
                has_field = true
            end
        end

        local data_text
        if has_field then
            data_text = table.concat(data_parts, "\n")
            if data_text == "[DONE]" then
                return { event = "done", data = nil }, nil
            end
            if #data_text == 0 then
                return { event = event_name, data = nil }, nil
            end
        else
            data_text = record_text:match("^%s*(.-)%s*$") or ""
            if #data_text == 0 or data_text:sub(1, 1) == ":" then
                return { event = nil, data = nil }, nil
            end
        end

        local data = jsonc.parse(data_text)
        if type(data) ~= "table" then
            return nil, chat_error.build(self, {
                phase = "response_parse",
                kind = "parse_error",
                message = "OpenAI returned invalid JSON in its response stream.",
                detail = "event=" .. tostring(event_name or ""),
            })
        end
        return { event = event_name or data.type, data = data }, nil
    end

    obj._api_error = function(self, event_name, data)
        if type(data) ~= "table" then return nil end
        local provider = data.error
        if provider == nil and event_name ~= "error" then return nil end
        local message = data.message or "Unknown OpenAI error"
        local detail = data.code or data.type
        if type(provider) == "table" then
            message = provider.message or message
            detail = provider.code or provider.type or detail
        elseif provider ~= nil then
            message = tostring(provider)
        end
        return chat_error.api_error(self, tostring(message), {
            detail = tostring(detail or ""),
            can_continue = not self._tool_side_effects_committed,
        })
    end

    obj._build_thinking_delta = function(self, delta)
        delta = tostring(delta or "")
        if #delta == 0 or not self:_summary_requested() then
            return "", "", self.recv_raw_msg, false
        end
        self._summary_delta_buffer = self._summary_delta_buffer .. delta
        return delta, jsonc.stringify({ type = "thinking", content = delta }, false),
            self.recv_raw_msg, false
    end

    obj._part_key = function(self, data, index_name)
        data = data or {}
        return table.concat({
            tostring(data.item_id or ""),
            tostring(data.output_index or ""),
            tostring(data[index_name] or ""),
        }, ":")
    end

    obj._track_part_delta = function(self, parts, data, index_name)
        local key = self:_part_key(data, index_name)
        parts[key] = tostring(parts[key] or "") .. tostring(data.delta or "")
    end

    obj._validate_part_done = function(self, parts, data, index_name, field)
        local key = self:_part_key(data, index_name)
        local streamed = parts[key]
        local final = tostring(data[field] or "")
        -- done is an integrity signal, not another output delta. Some gateways
        -- omit the corresponding delta events, in which case response.completed
        -- supplies the suffix later.
        if streamed ~= nil and streamed ~= final then
            return string.format("part=%s streamed_bytes=%d final_bytes=%d",
                key, #streamed, #final)
        end
        return nil
    end

    obj._build_answer_delta = function(self, delta)
        delta = tostring(delta or "")
        if #delta == 0 then
            return "", "", self.recv_raw_msg, false
        end
        self._answer_delta_buffer = self._answer_delta_buffer .. delta
        self.recv_raw_msg.role = common.role.assistant
        self.recv_raw_msg.message = self._answer_delta_buffer
        local response = jsonc.stringify({
            message = { role = common.role.assistant, content = delta }
        }, false)
        return tostring(misc.markdown(self.mark, delta) or ""), response,
            self.recv_raw_msg, false
    end

    obj._get_function_call = function(self, item_id, output_index)
        local key = non_empty(item_id) or ("output:" .. tostring(output_index or ""))
        local call = self._function_calls_by_item[key]
        if not call then
            call = { item_id = item_id, arguments = "", output_index = output_index }
            self._function_calls_by_item[key] = call
            self._function_call_order[#self._function_call_order + 1] = call
        end
        return call
    end

    obj._merge_function_item = function(self, item, output_index, is_final)
        if type(item) ~= "table" or item.type ~= "function_call" then
            return nil
        end
        local call = self:_get_function_call(item.id, output_index)
        local call_id = non_empty(item.call_id)
        if call_id then
            local owner = self._function_call_ids[call_id]
            if owner and owner ~= call then
                return "OpenAI returned duplicate function call_id=" .. call_id
            end
            if call.call_id and call.call_id ~= call_id then
                return "OpenAI changed a function call ID while streaming."
            end
            self._function_call_ids[call_id] = call
            call.call_id = call_id
        end
        if non_empty(item.name) then
            if call.name and call.name ~= item.name then
                return "OpenAI changed a function name while streaming."
            end
            call.name = item.name
        end
        if is_final and item.arguments ~= nil then
            local final_arguments = tostring(item.arguments)
            if #call.arguments > 0 and call.arguments ~= final_arguments then
                return "OpenAI function argument deltas did not match the final arguments."
            end
            call.arguments = final_arguments
            call.arguments_done = true
        end
        return nil
    end

    obj._append_function_arguments = function(self, data)
        local call = self:_get_function_call(data.item_id, data.output_index)
        if call.arguments_done then
            return "OpenAI returned function argument data after the done event."
        end
        call.arguments = call.arguments .. tostring(data.delta or "")
        return nil
    end

    obj._finish_function_arguments = function(self, data)
        local call = self:_get_function_call(data.item_id, data.output_index)
        local final_arguments = tostring(data.arguments or "")
        if #call.arguments > 0 and call.arguments ~= final_arguments then
            return "OpenAI function argument deltas did not match the done event."
        end
        if non_empty(data.name) then
            if call.name and call.name ~= data.name then
                return "OpenAI changed a function name while streaming."
            end
            call.name = data.name
        end
        call.arguments = final_arguments
        call.arguments_done = true
        return nil
    end

    obj._extract_final_text = function(self, response)
        local answer = {}
        local summary = {}
        for _, item in ipairs((response and response.output) or {}) do
            if item.type == "message" then
                for _, part in ipairs(item.content or {}) do
                    if part.type == "output_text" or part.type == "refusal" then
                        answer[#answer + 1] = tostring(part.text or part.refusal or "")
                    end
                end
            elseif item.type == "reasoning" then
                for _, part in ipairs(item.summary or {}) do
                    if part.type == "summary_text" then
                        summary[#summary + 1] = tostring(part.text or "")
                    end
                end
            end
        end
        return table.concat(answer), table.concat(summary)
    end

    obj._terminal_error = function(self, event_name, response)
        local status = tostring((response and response.status) or "")
        local details = response and response.incomplete_details
        local provider_error = response and response.error
        local message = "OpenAI response did not complete successfully."
        local detail = "event=" .. tostring(event_name) .. " status=" .. status
        if type(provider_error) == "table" and provider_error.message then
            message = tostring(provider_error.message)
            detail = tostring(provider_error.code or provider_error.type or detail)
        elseif type(details) == "table" then
            detail = tostring(details.reason or detail)
        end
        return chat_error.api_error(self, message, {
            detail = detail,
            can_continue = not self._tool_side_effects_committed,
        })
    end

    obj._complete_response = function(self, response)
        if type(response) ~= "table" or tostring(response.status or "") ~= "completed" then
            return nil, nil, self.recv_raw_msg, false,
                self:_terminal_error("response.completed", response)
        end
        if type(response.output) ~= "table" then
            return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                phase = "response_parse", kind = "parse_error",
                message = "OpenAI returned an invalid completed response.",
                detail = "response.output is not an array",
            })
        end

        -- Streaming item events are provisional. Only function calls present in
        -- the authoritative completed output may reach the execution phase.
        local completed_function_calls = {}
        for index, item in ipairs(response.output) do
            local completed_call
            if type(item) == "table" and item.type == "function_call" then
                completed_call = self:_get_function_call(item.id, index - 1)
                if completed_function_calls[completed_call] then
                    return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                        phase = "response_parse", kind = "parse_error",
                        message = "OpenAI returned inconsistent Function Calling data.",
                        detail = "The completed output contained a duplicate function call item.",
                    })
                end
                completed_function_calls[completed_call] = true
            end
            local merge_error = self:_merge_function_item(item, index - 1, true)
            if merge_error then
                return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                    phase = "response_parse", kind = "parse_error",
                    message = "OpenAI returned inconsistent Function Calling data.",
                    detail = merge_error,
                })
            end
        end
        for _, call in ipairs(self._function_call_order or {}) do
            if not completed_function_calls[call] then
                return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                    phase = "response_parse", kind = "parse_error",
                    message = "OpenAI returned inconsistent Function Calling data.",
                    detail = "A streamed function call was missing from the completed output.",
                })
            end
        end

        local answer, summary = self:_extract_final_text(response)
        if answer:sub(1, #self._answer_delta_buffer) ~= self._answer_delta_buffer then
            return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                phase = "response_parse", kind = "parse_error",
                message = "OpenAI final output did not match its streamed deltas.",
                detail = string.format("streamed_bytes=%d final_bytes=%d",
                    #self._answer_delta_buffer, #answer),
            })
        end
        if self:_summary_requested()
            and summary:sub(1, #self._summary_delta_buffer) ~= self._summary_delta_buffer then
            return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                phase = "response_parse", kind = "parse_error",
                message = "OpenAI reasoning summary did not match its streamed deltas.",
                detail = string.format("streamed_bytes=%d final_bytes=%d",
                    #self._summary_delta_buffer, #summary),
            })
        end

        local answer_suffix = answer:sub(#self._answer_delta_buffer + 1)
        local summary_suffix = ""
        if self:_summary_requested() then
            summary_suffix = summary:sub(#self._summary_delta_buffer + 1)
        end
        self._answer_delta_buffer = answer
        self._summary_delta_buffer = summary
        self._response_done = true
        self._terminal_event = "response.completed"
        self._completed_response_output = copy_array(response.output)
        self.recv_raw_msg.role = common.role.assistant
        self.recv_raw_msg.message = answer
        -- A non-streaming gateway, or a stream that omits optional deltas, can
        -- still provide an authoritative completed output. Emit only its suffix.
        if #answer_suffix > 0 or #summary_suffix > 0 then
            local message = {
                role = common.role.assistant,
                content = answer_suffix,
            }
            if #summary_suffix > 0 then
                message.thinking = summary_suffix
            end
            return tostring(misc.markdown(self.mark, answer_suffix) or ""),
                jsonc.stringify({ message = message }, false),
                self.recv_raw_msg, false
        end
        return "", "", self.recv_raw_msg, false
    end

    obj.recv_ai_msg = function(self, record)
        local parsed, parse_error = self:_parse_record(record)
        if not parsed then
            return nil, nil, self.recv_raw_msg, false, parse_error
        end
        local event_name = tostring(parsed.event or "")
        local data = parsed.data
        if #event_name == 0 and data == nil then
            return "", "", self.recv_raw_msg, false
        end
        if event_name == "done" then
            return "", "", self.recv_raw_msg, false
        end
        if self._response_done then
            return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                phase = "response_parse", kind = "parse_error",
                message = "OpenAI returned data after the completion event.",
                detail = "event=" .. event_name,
            })
        end

        self._stream_record_count = self._stream_record_count + 1
        debug:log("oasis.log", "openai_responses.recv_ai_msg", "event=" .. event_name)
        local api_error = self:_api_error(event_name, data)
        if api_error then
            return nil, nil, self.recv_raw_msg, false, api_error
        end

        if event_name == "response.reasoning_summary_text.delta" then
            self:_track_part_delta(self._summary_text_parts, data,
                "summary_index")
            return self:_build_thinking_delta(data and data.delta)
        elseif event_name == "response.output_text.delta" then
            self:_track_part_delta(self._output_text_parts, data,
                "content_index")
            return self:_build_answer_delta(data and data.delta)
        elseif event_name == "response.refusal.delta" then
            self:_track_part_delta(self._refusal_parts, data,
                "content_index")
            return self:_build_answer_delta(data and data.delta)
        elseif event_name == "response.reasoning_summary_text.done"
            or event_name == "response.output_text.done"
            or event_name == "response.refusal.done" then
            local parts = self._output_text_parts
            local index_name = "content_index"
            local field = "text"
            if event_name == "response.reasoning_summary_text.done" then
                parts = self._summary_text_parts
                index_name = "summary_index"
            elseif event_name == "response.refusal.done" then
                parts = self._refusal_parts
                field = data and data.refusal ~= nil and "refusal" or "text"
            end
            local done_error = self:_validate_part_done(parts, data or {},
                index_name, field)
            if done_error then
                return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                    phase = "response_parse", kind = "parse_error",
                    message = "OpenAI done event did not match its streamed deltas.",
                    detail = done_error,
                })
            end
        elseif event_name == "response.function_call_arguments.delta" then
            local err = self:_append_function_arguments(data or {})
            if err then
                return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                    phase = "response_parse", kind = "parse_error",
                    message = "OpenAI returned inconsistent Function Calling data.",
                    detail = err,
                })
            end
        elseif event_name == "response.function_call_arguments.done" then
            local err = self:_finish_function_arguments(data or {})
            if err then
                return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                    phase = "response_parse", kind = "parse_error",
                    message = "OpenAI returned inconsistent Function Calling data.",
                    detail = err,
                })
            end
        elseif event_name == "response.output_item.added" then
            local err = self:_merge_function_item(data and data.item,
                data and data.output_index, false)
            if err then
                return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                    phase = "response_parse", kind = "parse_error",
                    message = "OpenAI returned inconsistent Function Calling data.",
                    detail = err,
                })
            end
        elseif event_name == "response.output_item.done" then
            local err = self:_merge_function_item(data and data.item,
                data and data.output_index, true)
            if err then
                return nil, nil, self.recv_raw_msg, false, chat_error.build(self, {
                    phase = "response_parse", kind = "parse_error",
                    message = "OpenAI returned inconsistent Function Calling data.",
                    detail = err,
                })
            end
        elseif event_name == "response.completed" then
            return self:_complete_response(data and data.response)
        elseif event_name == "response.failed" or event_name == "response.incomplete" then
            self._response_done = true
            self._terminal_event = event_name
            return nil, nil, self.recv_raw_msg, false,
                self:_terminal_error(event_name, data and data.response)
        elseif type(data) == "table" and type(data.output) == "table"
            and data.status ~= nil then
            return self:_complete_response(data)
        end

        return "", "", self.recv_raw_msg, false
    end

    obj.validate_ai_response_complete = function(self)
        if self._response_done and self._terminal_event == "response.completed" then
            return nil
        end
        return chat_error.build(self, {
            phase = "response_parse", kind = "parse_error",
            message = "AI response ended before OpenAI reported completion.",
            detail = string.format("records=%d terminal=%s",
                tonumber(self._stream_record_count or 0),
                tostring(self._terminal_event or "none")),
            can_continue = not self._tool_side_effects_committed,
        })
    end

    obj.finalize_ai_response = function(self)
        if self._tool_calls_finalized then return nil end
        self._tool_calls_finalized = true

        local calls = self._function_call_order or {}
        if #calls == 0 then
            -- finalize_ai_response() runs only after the stream, output, and
            -- completion checks succeeded. This is the safe point to close a
            -- transient tool turn; clearing it in response.completed would
            -- incorrectly make a later output error look retryable.
            self._pending_provider_items = nil
            self.processed_tool_call_ids = {}
            self._processed_tool_results = {}
            self._tool_side_effects_committed = false
            return nil
        end
        if not self._request_tools_enabled then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling", kind = "unsupported_feature",
                message = "OpenAI requested another tool after Function Calling was disabled.",
                can_continue = false,
            })
        end

        for _, call in ipairs(calls) do
            if not call.arguments_done or not non_empty(call.call_id)
                or not non_empty(call.name) then
                return nil, nil, nil, false, chat_error.build(self, {
                    phase = "function_calling", kind = "parse_error",
                    message = "OpenAI returned an incomplete function call.",
                    detail = "item_id=" .. tostring(call.item_id or ""),
                    can_continue = false,
                })
            end
        end

        local ok, plain, response, speaker, used, err = pcall(function()
            return calling.process(self, calls)
        end)
        if not ok then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "tool_execution", kind = "tool_error",
                message = "Failed while executing an OpenAI tool call.",
                detail = tostring(plain), can_continue = false,
            })
        end
        if err then return nil, nil, nil, false, err end
        self._completed_tool_message = speaker
        return plain, response, speaker, used
    end

    obj.handle_tool_result = function(self, chat, speaker, msg)
        if speaker.role ~= "tool" then return nil end
        return calling.convert_tool_result(chat, speaker, msg)
    end

    obj.handle_tool_call = function(self, chat, speaker, msg)
        if speaker.role ~= common.role.assistant or not speaker.tool_calls then
            return nil
        end
        return calling.convert_tool_call(chat, speaker, msg)
    end

    obj.handle_tool_output = function(self, tool_info, chat)
        local info = type(tool_info) == "string" and jsonc.parse(tool_info) or nil
        if type(info) ~= "table" or type(info.tool_outputs) ~= "table"
            or #info.tool_outputs == 0 then
            return false
        end
        if type(self._completed_response_output) ~= "table" then
            return false
        end

        local calls = self._function_call_order or {}
        if #calls ~= #info.tool_outputs then
            return false
        end
        local expected = {}
        for _, call in ipairs(calls) do
            local call_id = tostring(call.call_id or "")
            if #call_id == 0 or expected[call_id] then
                return false
            end
            expected[call_id] = tostring(call.name or "")
        end
        local seen = {}
        for _, result in ipairs(info.tool_outputs) do
            local call_id = tostring(result.tool_call_id or result.id or "")
            local name = tostring(result.name or "")
            if not expected[call_id] or expected[call_id] ~= name or seen[call_id]
                or result.output == nil then
                return false
            end
            seen[call_id] = true
        end

        chat.messages = chat.messages or {}
        local initial_count = #chat.messages
        local assistant = self._completed_tool_message
        if type(assistant) ~= "table" or type(assistant.tool_calls) ~= "table"
            or #assistant.tool_calls == 0 then
            return false
        end
        table.insert(chat.messages, assistant)

        for _, result in ipairs(info.tool_outputs) do
            local added = ous.setup_msg(self, chat, {
                role = "tool",
                tool_call_id = result.tool_call_id or result.id,
                tool_name = result.name,
                name = result.name,
                content = type(result.output) == "string"
                    and result.output or (jsonc.stringify(result.output, false) or "null"),
            })
            if not added then
                while #chat.messages > initial_count do table.remove(chat.messages) end
                return false
            end
        end

        local pending = copy_array(self._pending_provider_items)
        for _, item in ipairs(self._completed_response_output) do
            pending[#pending + 1] = item
        end
        for _, result in ipairs(info.tool_outputs) do
            pending[#pending + 1] = {
                type = "function_call_output",
                call_id = tostring(result.tool_call_id or result.id or ""),
                output = type(result.output) == "string"
                    and result.output or (jsonc.stringify(result.output, false) or "null"),
            }
        end

        if info.reboot == true then self._reboot_required = true end
        self._pending_provider_items = pending
        self._completed_tool_message = nil
        return true
    end

    obj:_reset_stream_state(false)
    return obj
end

return openai_responses.new()
