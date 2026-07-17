#!/usr/bin/env lua

local jsonc           = require("luci.jsonc")
local common          = require("oasis.common")
local util            = require("luci.util")
local datactrl        = require("oasis.chat.datactrl")
local misc            = require("oasis.chat.misc")
local ous             = require("oasis.unified.chat.schema")
local debug           = require("oasis.chat.debug")
local calling         = require("oasis.chat.function.calling.anthropic")
local chat_error      = require("oasis.chat.error")
local response_framer = require("oasis.chat.response_framer")

local MAX_RESPONSE_BYTES = 4 * 1024 * 1024
local MAX_CONTENT_BLOCKS = 256
local MAX_STREAM_RECORDS = 65536

local function is_bounded_dense_array(value, max_items)
    if type(value) ~= "table" or #value > max_items then
        return false
    end

    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0
            or key > max_items then
            return false
        end
        count = count + 1
    end
    return count == #value
end

local function has_nested_empty_table(value, depth)
    if type(value) ~= "table" then
        return false
    end
    depth = depth or 0
    if next(value) == nil then
        return depth > 0
    end
    for _, child in pairs(value) do
        if has_nested_empty_table(child, depth + 1) then
            return true
        end
    end
    return false
end

local function copy_value(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[copy_value(key)] = copy_value(item)
    end
    return result
end

local function is_positive_integer(value)
    return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function stringify_object(value)
    local encoded = jsonc.stringify(value, false)
    if type(encoded) ~= "string" or encoded:match("^%s*%[%s*%]%s*$") then
        return "{}"
    end
    return encoded
end

local anthropic = {}

anthropic.new = function()
    local obj = {}

    obj.cfg = nil
    obj.format = nil
    obj.mark = {}
    obj.recv_raw_msg = { role = common.role.unknown, message = "" }
    obj._sysmsg_text = nil
    obj._reboot_required = false
    obj._sse_state = response_framer.new_sse(
        MAX_RESPONSE_BYTES, MAX_STREAM_RECORDS)

    obj._parse_error = function(self, message, detail, can_continue)
        return chat_error.build(self, {
            phase = "response_parse",
            kind = "parse_error",
            message = message,
            detail = detail,
            can_continue = can_continue ~= false
                and not self._tool_side_effects_committed,
        })
    end

    obj._clear_tool_cycle = function(self, preserve_side_effects)
        local side_effects_committed = self._tool_side_effects_committed == true
        self.processed_tool_call_ids = {}
        self._processed_tool_results = {}
        self._pending_provider_messages = {}
        self._pending_tool_input_json_by_id = {}
        self._active_tool_definitions = nil
        self._active_thinking = nil
        self._request_tools_enabled = false
        self._request_tool_names = {}
        self._request_tool_choice = nil
        self._request_thinking = nil
        self._tool_side_effects_committed = preserve_side_effects
            and side_effects_committed
            or false
    end

    obj._reset_response_state = function(self)
        response_framer.reset_sse(
            self._sse_state, MAX_RESPONSE_BYTES, MAX_STREAM_RECORDS)
        self._response_mode = nil
        self._transport_buffer = ""
        self._response_bytes_received = 0
        self._message_started = false
        self._message_delta_seen = false
        self._response_done = false
        self._terminal_event = nil
        self._stream_record_count = 0
        self._stop_reason = nil
        self._stop_sequence = nil
        self._blocks_by_index = {}
        self._block_count = 0
        self._max_block_index = -1
        self._tool_input_json_by_id = {}
        self._unknown_content_delta = false
        self._content_bytes = 0
        self._answer_text = ""
        self._thinking_text = ""
        self._completed_provider_content = nil
        self._completed_tool_calls = {}
        self._completed_tool_message = nil
        self._tool_calls_finalized = false
        self._tool_output_handled = false
    end

    obj.initialize = function(self, arg, format)
        self.cfg = datactrl.get_ai_service_cfg(arg, { format = format })
        self.format = format
        self._agent_mode = nil
        self._reboot_required = false
        self.mark = {}
        self.recv_raw_msg = { role = common.role.unknown, message = "" }
        self:_clear_tool_cycle()
        self:_reset_response_state()
    end

    obj.init_msg_buffer = function(self)
        self.recv_raw_msg.role = common.role.unknown
        self.recv_raw_msg.message = ""
        self.mark = {}
        -- convert_schema() runs before this hook. Preserve the provider-native
        -- tool cycle and only reset the parser for the response about to arrive.
        self:_reset_response_state()
    end

    obj.reset_ai_response_framer = function(self)
        self:_reset_response_state()
        if not self._tool_side_effects_committed then
            self:_clear_tool_cycle()
        end
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

    obj._thinking_visible = function(self)
        local format = self:get_format()
        return common.check_show_thinking_enabled(self)
            and (format == common.ai.format.chat
                or format == common.ai.format.prompt
                or format == common.ai.format.output)
    end

    obj._build_thinking_request = function(self, followup, max_tokens)
        if self:get_format() == common.ai.format.title then
            self._request_thinking = nil
            return nil
        end
        if followup and self._active_thinking ~= nil then
            self._request_thinking = copy_value(self._active_thinking)
            return copy_value(self._active_thinking)
        end

        local mode = tostring((self.cfg and self.cfg.thinking) or "disabled")
        local thinking
        if mode == "enabled" then
            local budget = self.cfg and self.cfg.budget_tokens
            if not is_positive_integer(budget) or budget < 1024 then
                error("Anthropic manual thinking requires budget_tokens >= 1024.")
            end
            if budget >= max_tokens then
                error("Anthropic manual thinking requires budget_tokens < max_tokens.")
            end
            thinking = {
                type = "enabled",
                budget_tokens = budget,
                display = self:_thinking_visible() and "summarized" or "omitted",
            }
        elseif mode == "adaptive" then
            thinking = {
                type = "adaptive",
                display = self:_thinking_visible() and "summarized" or "omitted",
            }
        elseif mode == "disabled" then
            thinking = { type = "disabled" }
        else
            error("Unsupported Anthropic thinking mode: " .. mode)
        end

        self._request_thinking = copy_value(thinking)
        return thinking
    end

    -- Convert Oasis chat history to the Anthropic Messages API. Provider-native
    -- tool-cycle messages live only in this service and replace the synthetic
    -- unified tool messages during the immediate continuation.
    obj.convert_schema = function(self, chat)
        if self.cfg and self.cfg.anthropic_config_error then
            error(tostring(self.cfg.anthropic_config_error))
        end
        local followup = type(self._pending_provider_messages) == "table"
            and #self._pending_provider_messages > 0
        if not followup then
            self:_clear_tool_cycle()
        end

        local system_buf = {}
        local messages = {}
        local pending_tool_results = {}
        local raw_input_replacements = {}

        local function flush_tool_results()
            if #pending_tool_results == 0 then
                return
            end
            local content = {}
            for _, tool_result in ipairs(pending_tool_results) do
                content[#content + 1] = {
                    type = "tool_result",
                    tool_use_id = tostring(tool_result.tool_call_id or ""),
                    content = tostring(tool_result.content or ""),
                }
            end
            messages[#messages + 1] = { role = "user", content = content }
            pending_tool_results = {}
        end

        for _, message in ipairs(chat.messages or {}) do
            local role = tostring(message.role or "")
            local text = tostring(message.content or message.message or "")
            local has_tool_calls = type(message.tool_calls) == "table"
                and #message.tool_calls > 0

            if followup and (role == "tool"
                or (role == common.role.assistant and has_tool_calls)) then
                -- Exact provider messages are appended below instead.
            elseif role == common.role.system then
                system_buf[#system_buf + 1] = text
            elseif role == common.role.user then
                flush_tool_results()
                messages[#messages + 1] = {
                    role = "user",
                    content = { { type = "text", text = text } },
                }
            elseif role == common.role.assistant then
                flush_tool_results()
                if has_tool_calls then
                    local content = {}
                    for _, tool_call in ipairs(message.tool_calls) do
                        local fn = tool_call["function"] or {}
                        content[#content + 1] = {
                            type = "tool_use",
                            id = tostring(tool_call.id or ""),
                            name = tostring(fn.name or ""),
                            input = ous.normalize_arguments(fn.arguments),
                        }
                    end
                    messages[#messages + 1] = {
                        role = "assistant",
                        content = content,
                    }
                else
                    messages[#messages + 1] = {
                        role = "assistant",
                        content = { { type = "text", text = text } },
                    }
                end
            elseif role == "tool" then
                pending_tool_results[#pending_tool_results + 1] = {
                    tool_call_id = message.tool_call_id,
                    content = text,
                }
            end
        end
        flush_tool_results()

        if followup then
            for _, provider_message in ipairs(self._pending_provider_messages) do
                local message_copy = copy_value(provider_message)
                for _, block in ipairs(message_copy.content or {}) do
                    if block.type == "tool_use" then
                        local raw_input = self._pending_tool_input_json_by_id[
                            tostring(block.id or "")
                        ]
                        if raw_input then
                            local placeholder = string.format(
                                "__OASIS_ANTHROPIC_TOOL_INPUT_%d__",
                                #raw_input_replacements + 1
                            )
                            block.input = placeholder
                            raw_input_replacements[#raw_input_replacements + 1] = {
                                placeholder = placeholder,
                                raw = raw_input,
                            }
                        end
                    end
                end
                messages[#messages + 1] = message_copy
            end
        end

        local max_tokens = tonumber(self.cfg and self.cfg.max_tokens) or 1024
        if not is_positive_integer(max_tokens) then
            error("Anthropic max_tokens must be a positive integer.")
        end

        local body = {
            model = tostring((self.cfg and self.cfg.model) or ""),
            max_tokens = max_tokens,
            messages = messages,
            stream = true,
        }
        body.thinking = self:_build_thinking_request(followup, max_tokens)

        local system_text = table.concat(system_buf, "\n")
        if #system_text == 0 and self._sysmsg_text
            and #tostring(self._sysmsg_text) > 0 then
            system_text = tostring(self._sysmsg_text)
        end
        if #system_text > 0 then
            body.system = system_text
        end

        body = calling.inject_schema(self, body, {
            followup = followup,
            force_none = followup and not self._agent_mode,
        })

        local encoded = jsonc.stringify(body, false)
        if type(encoded) ~= "string" then
            error("Failed to encode Anthropic request body.")
        end
        -- luci.jsonc cannot distinguish an empty Lua object from an empty array.
        encoded = encoded
            :gsub('"input"%s*:%s*%[%s*%]', '"input":{}')
            :gsub('"arguments"%s*:%s*%[%s*%]', '"arguments":{}')
            :gsub('"properties"%s*:%s*%[%s*%]', '"properties":{}')
        -- Inject validated raw Tool Use JSON last. Running any whole-body
        -- normalization after this point could mutate nested arrays/objects in
        -- the provider content that must be replayed unchanged.
        -- Replace from the last placeholder to the first. A provider-supplied
        -- input may itself contain text that looks like a later placeholder;
        -- reverse order ensures the real placeholder is consumed before any
        -- earlier raw input is inserted ahead of it.
        for index = #raw_input_replacements, 1, -1 do
            local replacement = raw_input_replacements[index]
            local pattern = '("input"%s*:%s*)"'
                .. replacement.placeholder .. '"'
            local replaced
            local count
            replaced, count = encoded:gsub(pattern, function(prefix)
                return prefix .. replacement.raw
            end, 1)
            if count ~= 1 then
                error("Failed to preserve Anthropic Tool Use input JSON.")
            end
            encoded = replaced
        end

        debug:log("oasis.log", "anthropic.convert_schema", string.format(
            "messages=%d bytes=%d stream=true thinking=%s tools=%d followup=%s",
            #messages,
            #encoded,
            tostring(body.thinking and body.thinking.type or "provider-default"),
            type(body.tools) == "table" and #body.tools or 0,
            tostring(followup)
        ))
        return encoded
    end

    obj.prepare_post_to_server = function(self, easy, callback, form, user_msg_json)
        easy:setopt_url(self.cfg.endpoint)
        easy:setopt_writefunction(callback)
        local headers = {
            "Content-Type: application/json",
            "Accept: text/event-stream",
            "x-api-key: " .. tostring(self.cfg.api_key or ""),
            "anthropic-version: 2023-06-01",
        }
        local endpoint = tostring(self.cfg.endpoint or ""):gsub("/+$", "")
        local official_endpoint = tostring(
            common.ai.service.anthropic.endpoint or ""
        ):gsub("/+$", "")
        if endpoint == official_endpoint
            and self._request_tools_enabled
            and type(self._request_thinking) == "table"
            and self._request_thinking.type == "enabled" then
            headers[#headers + 1]
                = "anthropic-beta: interleaved-thinking-2025-05-14"
        end
        easy:setopt_httpheader(headers)
        easy:setopt_httppost(form)
        easy:setopt_postfields(user_msg_json)
    end

    obj._framing_error = function(self, message, detail)
        return chat_error.build(self, {
            phase = "response_parse",
            kind = "parse_error",
            message = message,
            detail = detail,
            can_continue = not self._tool_side_effects_committed,
        })
    end

    obj.frame_ai_response = function(self, chunk, eof)
        local incoming = tostring(chunk or "")
        local received = tonumber(self._response_bytes_received or 0)
        if #incoming > MAX_RESPONSE_BYTES - received then
            return {}, self:_framing_error(
                "Anthropic response exceeded the total size limit.",
                "max_bytes=" .. MAX_RESPONSE_BYTES)
        end
        self._response_bytes_received = received + #incoming

        if self._response_mode == "json" then
            self._transport_buffer = self._transport_buffer .. incoming
            if #self._transport_buffer > MAX_RESPONSE_BYTES then
                return {}, self:_framing_error(
                    "Incomplete Anthropic JSON response exceeded the buffer limit.",
                    "max_bytes=" .. MAX_RESPONSE_BYTES)
            end
            if not eof then
                return {}, nil
            end
            local record = self._transport_buffer
            self._transport_buffer = ""
            return record:find("%S") and { record } or {}, nil
        end

        if self._response_mode == nil then
            self._transport_buffer = self._transport_buffer .. incoming
            if #self._transport_buffer > MAX_RESPONSE_BYTES then
                return {}, self:_framing_error(
                    "Incomplete Anthropic response exceeded the buffer limit.",
                    "max_bytes=" .. MAX_RESPONSE_BYTES)
            end
            local first = self._transport_buffer:match("^%s*(.)")
            if not first then
                if eof then
                    self._transport_buffer = ""
                end
                return {}, nil
            end
            if first == "{" or first == "[" then
                self._response_mode = "json"
                if not eof then
                    return {}, nil
                end
                local record = self._transport_buffer
                self._transport_buffer = ""
                return { record }, nil
            end

            self._response_mode = "sse"
            local buffered = self._transport_buffer
            self._transport_buffer = ""
            local frames, frame_error = response_framer.push_sse(
                self._sse_state, buffered, eof)
            if frame_error then
                return frames, self:_framing_error(
                    "Anthropic SSE framing failed.", frame_error)
            end
            return frames, nil
        end

        local frames, frame_error = response_framer.push_sse(
            self._sse_state, incoming, eof)
        if frame_error then
            return frames, self:_framing_error(
                "Anthropic SSE framing failed.", frame_error)
        end
        return frames, nil
    end

    obj._parse_record = function(self, record)
        local text = tostring(record or "")
        local first = text:match("^%s*(.)")
        if first == "{" or first == "[" then
            local data = jsonc.parse(text)
            if type(data) ~= "table" then
                return nil, self:_parse_error(
                    "Anthropic returned invalid JSON.", "response_mode=json")
            end
            return { event = "full_message", data = data }, nil
        end

        local event_name
        local data_parts = {}
        local has_sse_field = false
        for line in (text .. "\n"):gmatch("(.-)\n") do
            if line:sub(1, 1) == ":" then
                has_sse_field = true
            elseif line:sub(1, 6) == "event:" then
                event_name = line:sub(7):gsub("^%s+", ""):gsub("%s+$", "")
                has_sse_field = true
            elseif line:sub(1, 5) == "data:" then
                data_parts[#data_parts + 1] = line:sub(6):gsub("^%s?", "")
                has_sse_field = true
            end
        end
        if not has_sse_field then
            return nil, self:_parse_error(
                "Anthropic response was neither SSE nor JSON.")
        end
        if #data_parts == 0 then
            return { event = event_name, data = nil }, nil
        end

        local data_text = table.concat(data_parts, "\n")
        if data_text == "[DONE]" then
            return { event = "done", data = nil }, nil
        end
        local data = jsonc.parse(data_text)
        if type(data) ~= "table" then
            return nil, self:_parse_error(
                "Anthropic SSE event contained invalid JSON.",
                "event=" .. tostring(event_name or ""))
        end
        if event_name and data.type and event_name ~= tostring(data.type) then
            return nil, self:_parse_error(
                "Anthropic SSE event name did not match its payload.",
                "event=" .. event_name .. " payload_type=" .. tostring(data.type))
        end
        return { event = event_name or data.type, data = data }, nil
    end

    obj._api_error = function(self, event_name, data)
        if type(data) ~= "table" then
            return nil
        end
        if event_name ~= "error" and data.type ~= "error" and data.error == nil then
            return nil
        end

        local provider = data.error
        local message = data.message or "Unknown Anthropic error"
        local detail = data.type
        if type(provider) == "table" then
            message = provider.message or message
            detail = provider.type or provider.code or detail
        elseif provider ~= nil then
            message = tostring(provider)
        end
        return chat_error.api_error(self, tostring(message), {
            detail = tostring(detail or ""),
            can_continue = not self._tool_side_effects_committed,
        })
    end

    obj._reserve_content_bytes = function(self, value)
        local size = type(value) == "string"
            and #value
            or #tostring(value or "")
        local total = tonumber(self._content_bytes or 0) + size
        if total > MAX_RESPONSE_BYTES then
            return self:_parse_error(
                "Anthropic content exceeded the accumulation limit.",
                "max_bytes=" .. MAX_RESPONSE_BYTES)
        end
        self._content_bytes = total
        return nil
    end

    obj._start_content_block = function(self, data)
        if not self._message_started or self._message_delta_seen then
            return nil, self:_parse_error(
                "Anthropic started a content block out of sequence.")
        end
        local index = data and data.index
        if type(index) ~= "number" or index < 0 or index % 1 ~= 0
            or index ~= self._block_count
            or self._blocks_by_index[index] ~= nil
            or self._block_count >= MAX_CONTENT_BLOCKS then
            return nil, self:_parse_error(
                "Anthropic returned an invalid content block sequence.",
                "index=" .. tostring(index)
                    .. " expected=" .. tostring(self._block_count)
                    .. " max_blocks=" .. MAX_CONTENT_BLOCKS)
        end
        local content = data.content_block
        if type(content) ~= "table" or #tostring(content.type or "") == 0 then
            return nil, self:_parse_error(
                "Anthropic returned an invalid content block start.",
                "index=" .. tostring(index))
        end

        content = copy_value(content)
        local block_type = tostring(content.type)
        local state = {
            type = block_type,
            content = content,
            stopped = false,
            text_parts = {},
            thinking_parts = {},
            signature_parts = {},
            input_json_parts = {},
        }
        if block_type == "text" then
            content.text = tostring(content.text or "")
            if #content.text > 0 then
                state.text_parts[1] = content.text
            end
            local size_error = self:_reserve_content_bytes(content.text)
            if size_error then
                return nil, size_error
            end
        elseif block_type == "thinking" then
            content.thinking = tostring(content.thinking or "")
            content.signature = tostring(content.signature or "")
            if #content.thinking > 0 then
                state.thinking_parts[1] = content.thinking
            end
            if #content.signature > 0 then
                state.signature_parts[1] = content.signature
            end
            local size_error = self:_reserve_content_bytes(
                content.thinking .. content.signature)
            if size_error then
                return nil, size_error
            end
        elseif block_type == "tool_use" then
            content.id = tostring(content.id or "")
            content.name = tostring(content.name or "")
            if content.input == nil then
                content.input = {}
            end
            if type(content.input) ~= "table" or #content.input > 0 then
                return nil, self:_parse_error(
                    "Anthropic returned invalid initial Tool Use input.",
                    "index=" .. tostring(index))
            end
        elseif block_type == "redacted_thinking" then
            content.data = tostring(content.data or "")
            local size_error = self:_reserve_content_bytes(content.data)
            if size_error then
                return nil, size_error
            end
        end

        self._blocks_by_index[index] = state
        self._block_count = self._block_count + 1
        if index > self._max_block_index then
            self._max_block_index = index
        end

        if block_type == "thinking" and #content.thinking > 0 then
            return { kind = "thinking", text = content.thinking }, nil
        elseif block_type == "text" and #content.text > 0 then
            return { kind = "text", text = content.text }, nil
        end
        return { kind = "none" }, nil
    end

    obj._apply_content_delta = function(self, data)
        if self._message_delta_seen then
            return nil, self:_parse_error(
                "Anthropic returned content after the message delta.")
        end
        local index = data and data.index
        local state = self._blocks_by_index[index]
        if type(state) ~= "table" or state.stopped then
            return nil, self:_parse_error(
                "Anthropic returned a delta for an inactive content block.",
                "index=" .. tostring(index))
        end
        local delta = data.delta
        if type(delta) ~= "table" then
            return nil, self:_parse_error(
                "Anthropic returned an invalid content block delta.",
                "index=" .. tostring(index))
        end

        local delta_type = tostring(delta.type or "")
        if delta_type == "text_delta" then
            if state.type ~= "text" then
                return nil, self:_parse_error(
                    "Anthropic sent text for a non-text content block.",
                    "index=" .. tostring(index))
            end
            local value = tostring(delta.text or "")
            local size_error = self:_reserve_content_bytes(value)
            if size_error then
                return nil, size_error
            end
            state.text_parts[#state.text_parts + 1] = value
            return { kind = "text", text = value }, nil
        elseif delta_type == "thinking_delta" then
            if state.type ~= "thinking" then
                return nil, self:_parse_error(
                    "Anthropic sent thinking for a non-thinking content block.",
                    "index=" .. tostring(index))
            end
            local value = tostring(delta.thinking or "")
            local size_error = self:_reserve_content_bytes(value)
            if size_error then
                return nil, size_error
            end
            state.thinking_parts[#state.thinking_parts + 1] = value
            return { kind = "thinking", text = value }, nil
        elseif delta_type == "signature_delta" then
            if state.type ~= "thinking" then
                return nil, self:_parse_error(
                    "Anthropic sent a signature for a non-thinking content block.",
                    "index=" .. tostring(index))
            end
            local value = tostring(delta.signature or "")
            local size_error = self:_reserve_content_bytes(value)
            if size_error then
                return nil, size_error
            end
            state.signature_parts[#state.signature_parts + 1] = value
        elseif delta_type == "input_json_delta" then
            if state.type ~= "tool_use" then
                return nil, self:_parse_error(
                    "Anthropic sent tool input for a non-tool content block.",
                    "index=" .. tostring(index))
            end
            local value = tostring(delta.partial_json or "")
            local size_error = self:_reserve_content_bytes(value)
            if size_error then
                return nil, size_error
            end
            state.input_json_parts[#state.input_json_parts + 1] = value
        elseif delta_type == "citations_delta" then
            if state.type ~= "text" or type(delta.citation) ~= "table" then
                return nil, self:_parse_error(
                    "Anthropic sent a citation for an incompatible content block.",
                    "index=" .. tostring(index))
            end
            state.content.citations = state.content.citations or {}
            local citation_json = jsonc.stringify(delta.citation, false) or ""
            local size_error = self:_reserve_content_bytes(citation_json)
            if size_error then
                return nil, size_error
            end
            state.content.citations[#state.content.citations + 1]
                = copy_value(delta.citation)
        else
            self._unknown_content_delta = true
        end
        -- Unknown delta types may be introduced in the future. They are not
        -- user-visible and are ignored without disturbing known block state.
        return { kind = "none" }, nil
    end

    obj._stop_content_block = function(self, data)
        if self._message_delta_seen then
            return self:_parse_error(
                "Anthropic stopped content after the message delta.")
        end
        local index = data and data.index
        local state = self._blocks_by_index[index]
        if type(state) ~= "table" or state.stopped then
            return self:_parse_error(
                "Anthropic stopped an inactive content block.",
                "index=" .. tostring(index))
        end

        if state.type == "text" then
            state.content.text = table.concat(state.text_parts)
        elseif state.type == "thinking" then
            state.content.thinking = table.concat(state.thinking_parts)
            state.content.signature = table.concat(state.signature_parts)
        elseif state.type == "tool_use" then
            local input_json = table.concat(state.input_json_parts)
            if #input_json > 0 then
                local trimmed = input_json:match("^%s*(.-)%s*$") or ""
                if trimmed:sub(1, 1) ~= "{" or trimmed:sub(-1) ~= "}" then
                    return self:_parse_error(
                        "Anthropic returned incomplete Tool Use JSON.",
                        "index=" .. tostring(index))
                end
                local ok, parsed = pcall(jsonc.parse, trimmed)
                if (not ok) or type(parsed) ~= "table" or #parsed > 0 then
                    return self:_parse_error(
                        "Anthropic returned invalid Tool Use JSON.",
                        "index=" .. tostring(index))
                end
                state.content.input = parsed
                self._tool_input_json_by_id[state.content.id] = trimmed
            elseif type(state.content.input) ~= "table" or #state.content.input > 0 then
                return self:_parse_error(
                    "Anthropic returned non-object Tool Use input.",
                    "index=" .. tostring(index))
            end
        end
        state.stopped = true
        return nil
    end

    obj._finish_provider_message = function(self, content, stop_reason, streamed)
        if not is_bounded_dense_array(content, MAX_CONTENT_BLOCKS) then
            return self:_parse_error(
                "Anthropic returned an invalid or oversized final content array.",
                "max_blocks=" .. MAX_CONTENT_BLOCKS)
        end

        if not streamed then
            local ok, encoded_content = pcall(jsonc.stringify, content, false)
            if not ok or type(encoded_content) ~= "string" then
                return self:_parse_error(
                    "Anthropic returned content that could not be measured.")
            end
            if #encoded_content > MAX_RESPONSE_BYTES then
                return self:_parse_error(
                    "Anthropic content exceeded the accumulation limit.",
                    "max_bytes=" .. MAX_RESPONSE_BYTES)
            end
            self._content_bytes = #encoded_content
        end

        local answer_parts = {}
        local thinking_parts = {}
        local calls = {}
        for _, block in ipairs(content) do
            if type(block) ~= "table" or #tostring(block.type or "") == 0 then
                return self:_parse_error(
                    "Anthropic returned an invalid final content block.")
            end
            if block.type == "text" then
                answer_parts[#answer_parts + 1] = tostring(block.text or "")
            elseif block.type == "thinking" then
                thinking_parts[#thinking_parts + 1] = tostring(block.thinking or "")
            elseif block.type == "tool_use" then
                local tool_id = tostring(block.id or "")
                local raw_input = self._tool_input_json_by_id[tool_id]
                if raw_input == nil and has_nested_empty_table(block.input, 0) then
                    return self:_parse_error(
                        "Anthropic Tool Use contained an ambiguous empty nested value.",
                        "The endpoint did not provide lossless input_json_delta data for Tool Use replay.")
                end
                calls[#calls + 1] = {
                    id = tool_id,
                    name = tostring(block.name or ""),
                    input = copy_value(block.input),
                    input_json = raw_input,
                }
            end
        end

        local answer = table.concat(answer_parts)
        local thinking = table.concat(thinking_parts)
        self._answer_text = answer
        self._thinking_text = thinking

        stop_reason = tostring(stop_reason or "")
        local has_tools = #calls > 0
        if (stop_reason == "tool_use") ~= has_tools then
            return self:_parse_error(
                "Anthropic stop_reason did not match its Tool Use blocks.",
                "stop_reason=" .. stop_reason .. " tool_calls=" .. #calls)
        end
        if stop_reason == "max_tokens"
            or stop_reason == "model_context_window_exceeded" then
            return chat_error.api_error(self,
                "Anthropic stopped before completing the response.", {
                    detail = "stop_reason=" .. stop_reason,
                    can_continue = not self._tool_side_effects_committed,
                })
        elseif stop_reason == "pause_turn" then
            return chat_error.build(self, {
                phase = "response_parse",
                kind = "unsupported_feature",
                message = "Anthropic requested a server-tool continuation that Oasis does not support.",
                detail = "stop_reason=pause_turn",
                can_continue = not self._tool_side_effects_committed,
            })
        elseif stop_reason == "refusal" then
            return chat_error.api_error(self, "Anthropic refused the request.", {
                detail = "stop_reason=refusal",
                -- Anthropic requires the triggering turn to be removed before
                -- the conversation continues. Force the caller to end/reset
                -- this in-memory context rather than retrying it in place.
                can_continue = false,
            })
        elseif stop_reason ~= "end_turn" and stop_reason ~= "stop_sequence"
            and stop_reason ~= "tool_use" then
            return self:_parse_error(
                "Anthropic returned an unsupported stop_reason.",
                "stop_reason=" .. stop_reason)
        end

        if has_tools then
            if self._unknown_content_delta then
                return self:_parse_error(
                    "Anthropic used an unsupported content delta during a Tool Use turn.")
            end
            for _, block in ipairs(content) do
                if block.type == "thinking"
                    and #tostring(block.signature or "") == 0 then
                    return self:_parse_error(
                        "Anthropic omitted a thinking signature from a Tool Use turn.")
                elseif block.type == "redacted_thinking"
                    and #tostring(block.data or "") == 0 then
                    return self:_parse_error(
                        "Anthropic returned an invalid redacted thinking block.")
                end
            end
        end

        self._stop_reason = stop_reason
        self._completed_provider_content = copy_value(content)
        self._completed_tool_calls = calls
        self._response_done = true
        self.recv_raw_msg.role = common.role.assistant
        self.recv_raw_msg.message = answer
        return nil
    end

    obj._assemble_stream_content = function(self)
        if self._block_count == 0 then
            return {}, nil
        end
        local content = {}
        for index = 0, self._max_block_index do
            local state = self._blocks_by_index[index]
            if type(state) ~= "table" then
                return nil, self:_parse_error(
                    "Anthropic content block indices were not contiguous.",
                    "missing_index=" .. index)
            end
            if not state.stopped then
                return nil, self:_parse_error(
                    "Anthropic ended with an open content block.",
                    "index=" .. index)
            end
            content[#content + 1] = copy_value(state.content)
        end
        return content, nil
    end

    obj._complete_full_message = function(self, message)
        if type(message) ~= "table" then
            return nil, nil, self.recv_raw_msg, false,
                self:_parse_error("Anthropic returned an invalid message response.")
        end
        local api_error = self:_api_error("full_message", message)
        if api_error then
            return nil, nil, self.recv_raw_msg, false, api_error
        end
        if message.type ~= nil and message.type ~= "message" then
            return nil, nil, self.recv_raw_msg, false,
                self:_parse_error("Anthropic returned an unexpected JSON response.",
                    "type=" .. tostring(message.type))
        end
        if message.role ~= nil and message.role ~= "assistant" then
            return nil, nil, self.recv_raw_msg, false,
                self:_parse_error("Anthropic returned a non-assistant message.")
        end

        if not is_bounded_dense_array(message.content, MAX_CONTENT_BLOCKS) then
            return nil, nil, self.recv_raw_msg, false,
                self:_parse_error(
                    "Anthropic returned an invalid or oversized content array.",
                    "max_blocks=" .. MAX_CONTENT_BLOCKS)
        end
        local content = copy_value(message.content)
        local finish_error = self:_finish_provider_message(
            content, message.stop_reason, false)
        if finish_error then
            return nil, nil, self.recv_raw_msg, false, finish_error
        end
        self._terminal_event = "full_message"

        local response_message = {
            role = common.role.assistant,
            content = self._answer_text,
        }
        if self:_thinking_visible() and #self._thinking_text > 0 then
            response_message.thinking = self._thinking_text
        end
        return tostring(misc.markdown(self.mark, self._answer_text) or ""),
            jsonc.stringify({ message = response_message }, false),
            self.recv_raw_msg,
            false
    end

    obj.recv_ai_msg = function(self, record)
        local parsed, parse_error = self:_parse_record(record)
        if not parsed then
            return nil, nil, self.recv_raw_msg, false, parse_error
        end
        local event_name = tostring(parsed.event or "")
        local data = parsed.data
        if event_name == "full_message" then
            return self:_complete_full_message(data)
        end
        if #event_name == 0 or event_name == "ping" or event_name == "done" then
            return "", "", self.recv_raw_msg, false
        end
        if self._response_done then
            return nil, nil, self.recv_raw_msg, false, self:_parse_error(
                "Anthropic returned data after message_stop.",
                "event=" .. event_name)
        end

        self._stream_record_count = self._stream_record_count + 1
        if self._stream_record_count > MAX_STREAM_RECORDS then
            return nil, nil, self.recv_raw_msg, false, self:_parse_error(
                "Anthropic response exceeded the event limit.",
                "max_events=" .. MAX_STREAM_RECORDS)
        end
        debug:log("oasis.log", "anthropic.recv_ai_msg", string.format(
            "event=%s index=%s",
            event_name,
            tostring(type(data) == "table" and data.index or "")
        ))
        local api_error = self:_api_error(event_name, data)
        if api_error then
            return nil, nil, self.recv_raw_msg, false, api_error
        end

        if event_name == "message_start" then
            if self._message_started or type(data) ~= "table"
                or type(data.message) ~= "table" then
                return nil, nil, self.recv_raw_msg, false, self:_parse_error(
                    "Anthropic returned an invalid message_start event.")
            end
            if data.message.role ~= nil and data.message.role ~= "assistant" then
                return nil, nil, self.recv_raw_msg, false, self:_parse_error(
                    "Anthropic started a non-assistant message.")
            end
            self._message_started = true
        elseif event_name == "content_block_start" then
            local _, err = self:_start_content_block(data)
            if err then
                return nil, nil, self.recv_raw_msg, false, err
            end
        elseif event_name == "content_block_delta" then
            local _, err = self:_apply_content_delta(data)
            if err then
                return nil, nil, self.recv_raw_msg, false, err
            end
        elseif event_name == "content_block_stop" then
            local err = self:_stop_content_block(data)
            if err then
                return nil, nil, self.recv_raw_msg, false, err
            end
        elseif event_name == "message_delta" then
            if not self._message_started
                or type(data) ~= "table" or type(data.delta) ~= "table" then
                return nil, nil, self.recv_raw_msg, false, self:_parse_error(
                    "Anthropic returned an invalid message_delta event.")
            end
            if not self._message_delta_seen then
                local _, assemble_error = self:_assemble_stream_content()
                if assemble_error then
                    return nil, nil, self.recv_raw_msg, false, assemble_error
                end
            end
            self._message_delta_seen = true
            if data.delta.stop_reason ~= nil then
                local stop_reason = tostring(data.delta.stop_reason)
                if self._stop_reason ~= nil
                    and tostring(self._stop_reason) ~= stop_reason then
                    return nil, nil, self.recv_raw_msg, false, self:_parse_error(
                        "Anthropic changed stop_reason across message_delta events.")
                end
                self._stop_reason = stop_reason
            end
            if data.delta.stop_sequence ~= nil then
                self._stop_sequence = data.delta.stop_sequence
            end
        elseif event_name == "message_stop" then
            if not self._message_started or not self._message_delta_seen
                or self._stop_reason == nil then
                return nil, nil, self.recv_raw_msg, false, self:_parse_error(
                    "Anthropic stopped before reporting message completion.")
            end
            local content, assemble_error = self:_assemble_stream_content()
            if assemble_error then
                return nil, nil, self.recv_raw_msg, false, assemble_error
            end
            local finish_error = self:_finish_provider_message(
                content, self._stop_reason, true)
            if finish_error then
                return nil, nil, self.recv_raw_msg, false, finish_error
            end
            self._terminal_event = "message_stop"

            -- Anthropic can report a classifier refusal only after text has
            -- already streamed. Keep all Anthropic text/thinking private until
            -- the final stop reason is accepted, then release the completed
            -- response in one event so refused or truncated output is discarded.
            local response_message = {
                role = common.role.assistant,
                content = self._answer_text,
            }
            if self:_thinking_visible() and #self._thinking_text > 0 then
                response_message.thinking = self._thinking_text
            end
            return tostring(misc.markdown(self.mark, self._answer_text) or ""),
                jsonc.stringify({ message = response_message }, false),
                self.recv_raw_msg,
                false
        end

        -- Unknown event types are ignored for forward compatibility.
        return "", "", self.recv_raw_msg, false
    end

    obj.validate_ai_response_complete = function(self)
        if self._response_done
            and (self._terminal_event == "message_stop"
                or self._terminal_event == "full_message") then
            return nil
        end
        return self:_parse_error(
            "AI response ended before Anthropic reported completion.",
            string.format("records=%d terminal=%s",
                tonumber(self._stream_record_count or 0),
                tostring(self._terminal_event or "none")))
    end

    obj.finalize_ai_response = function(self)
        if self._tool_calls_finalized then
            return nil
        end
        self._tool_calls_finalized = true

        local calls = self._completed_tool_calls or {}
        if #calls == 0 then
            -- Provider continuation state is no longer needed, but retain the
            -- side-effect guard until the caller has accepted/stored this final
            -- response. A later fresh request clears it in convert_schema().
            self:_clear_tool_cycle(true)
            return nil
        end
        if not self._request_tools_enabled then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "function_calling",
                kind = "unsupported_feature",
                message = "Anthropic requested a tool when Function Calling was disabled.",
                can_continue = false,
            })
        end

        local ok, plain, response, speaker, used, err = pcall(function()
            return calling.process(self, calls)
        end)
        if not ok then
            return nil, nil, nil, false, chat_error.build(self, {
                phase = "tool_execution",
                kind = "tool_error",
                message = "Failed while executing an Anthropic tool call.",
                detail = tostring(plain),
                can_continue = false,
            })
        end
        if err then
            return nil, nil, nil, false, err
        end
        if type(speaker) == "table" then
            speaker.content = self._answer_text
        end
        self._completed_tool_message = speaker
        return plain, response, speaker, used
    end

    obj.handle_tool_output = function(self, tool_info, chat)
        if self._tool_output_handled or type(chat) ~= "table" then
            return false
        end
        local info = type(tool_info) == "string" and jsonc.parse(tool_info) or nil
        local outputs = info and info.tool_outputs
        local calls = self._completed_tool_calls or {}
        if type(outputs) ~= "table" or #outputs == 0 or #outputs ~= #calls
            or type(self._completed_provider_content) ~= "table" then
            return false
        end

        local output_by_id = {}
        for _, output in ipairs(outputs) do
            local call_id = tostring(output.tool_call_id or output.id or "")
            if #call_id == 0 or output_by_id[call_id] ~= nil or output.output == nil then
                return false
            end
            output_by_id[call_id] = output
        end

        local tool_calls = {}
        local tool_results = {}
        for _, call in ipairs(calls) do
            local output = output_by_id[call.id]
            if type(output) ~= "table" or tostring(output.name or "") ~= call.name then
                return false
            end
            tool_calls[#tool_calls + 1] = {
                id = call.id,
                type = "function",
                ["function"] = {
                    name = call.name,
                    arguments = stringify_object(call.input),
                },
            }
            tool_results[#tool_results + 1] = {
                type = "tool_result",
                tool_use_id = call.id,
                content = type(output.output) == "string"
                    and output.output
                    or jsonc.stringify(output.output, false),
            }
        end

        local original_count = #(chat.messages or {})
        chat.messages = chat.messages or {}
        local setup_ok, setup_result = pcall(function()
            return ous.setup_msg(self, chat, {
                role = common.role.assistant,
                content = self._answer_text,
                tool_calls = tool_calls,
            })
        end)
        local assistant_ok = setup_ok and setup_result == true
        if assistant_ok then
            for index, call in ipairs(calls) do
                setup_ok, setup_result = pcall(function()
                    return ous.setup_msg(self, chat, {
                        role = "tool",
                        tool_call_id = call.id,
                        name = call.name,
                        content = tool_results[index].content,
                    })
                end)
                if not setup_ok or setup_result ~= true then
                    assistant_ok = false
                    break
                end
            end
        end
        if not assistant_ok then
            while #chat.messages > original_count do
                table.remove(chat.messages)
            end
            return false
        end

        self._pending_provider_messages[#self._pending_provider_messages + 1] = {
            role = "assistant",
            content = copy_value(self._completed_provider_content),
        }
        self._pending_provider_messages[#self._pending_provider_messages + 1] = {
            role = "user",
            content = copy_value(tool_results),
        }
        for _, call in ipairs(calls) do
            if call.input_json ~= nil then
                self._pending_tool_input_json_by_id[call.id] = call.input_json
            end
        end
        self._active_thinking = copy_value(self._request_thinking)
        self._tool_output_handled = true
        self._reboot_required = self._reboot_required or info.reboot == true
        return true
    end

    obj.handle_tool_result = function(self, chat, speaker, msg)
        return calling.convert_tool_result(chat, speaker, msg)
    end

    obj.handle_tool_call = function(self, chat, speaker, msg)
        return calling.convert_tool_call(chat, speaker, msg)
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

    return obj
end

return anthropic.new()
