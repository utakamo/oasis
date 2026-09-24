#!/usr/bin/env lua

local jsonc  = require("luci.jsonc")
local common = require("oasis.common")
local uci    = require("luci.model.uci").cursor()
local debug  = require("oasis.chat.debug")
local ous	 = require("oasis.unified.chat.schema")
local chat_error = require("oasis.chat.error")
local policy = require("oasis.chat.function.calling.policy")

local M = {}

local function build_error(self, kind, message, detail)
	return chat_error.build(self, {
		phase = "function_calling",
		kind = kind,
		message = message,
		detail = detail,
		can_continue = not (type(self) == "table"
			and self._tool_side_effects_committed == true),
	})
end

local function parse_arguments(self, tool_call)
	local fn = type(tool_call["function"]) == "table"
		and tool_call["function"] or {}
	local raw = fn.arguments
	local parsed

	if type(raw) == "table" then
		parsed = raw
	elseif type(raw) == "string" then
		local trimmed = raw:match("^%s*(.-)%s*$") or ""
		if trimmed:sub(1, 1) ~= "{" or trimmed:sub(-1) ~= "}" then
			return nil, nil, build_error(self, "parse_error",
				"OpenAI returned invalid Function Calling arguments.",
				"tool_call_id=" .. tostring(tool_call.id or ""))
		end
		local ok
		ok, parsed = pcall(jsonc.parse, trimmed)
		if not ok then
			parsed = nil
		end
	else
		parsed = nil
	end

	if not policy.is_json_object(parsed) then
		return nil, nil, build_error(self, "parse_error",
			"OpenAI returned non-object Function Calling arguments.",
			"tool_call_id=" .. tostring(tool_call.id or ""))
	end

	local encoded, encode_error = policy.stringify_object(parsed)
	if not encoded then
		return nil, nil, build_error(self, "parse_error",
			"OpenAI returned invalid Function Calling arguments.",
			"tool_call_id=" .. tostring(tool_call.id or "")
				.. " reason=" .. tostring(encode_error))
	end
	return parsed, encoded, nil
end

function M.serialize_function_arguments(arguments)
	local normalized = ous.normalize_arguments(arguments)
	local encoded = policy.stringify_object(normalized)
	return encoded or "{}"
end

function M.detect(message)
	return type(message) == "table"
		and type(message.tool_calls) == "table"
		and next(message.tool_calls) ~= nil
end

function M.process(self, message)
	if not M.detect(message) then
		return nil
	end

	local is_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
	if not (is_tool and common.check_function_calling_enabled(self)
		and message and message.tool_calls) then
		return nil, nil, nil, false, build_error(self, "unsupported_feature",
			"OpenAI requested a tool when Function Calling was disabled.")
	end

	debug:log("oasis.log", "recv_ai_msg", "is_tool (local_tool flag is enabled)")
	local prepared = {}
	local batch_ids = {}
	self.processed_tool_call_ids = self.processed_tool_call_ids or {}
	self._processed_tool_results = self._processed_tool_results or {}
	local call_count = policy.dense_array_length(message.tool_calls)
	if call_count == nil then
		return nil, nil, nil, false, build_error(self, "parse_error",
			"OpenAI returned a sparse or invalid Function Calling batch.")
	end

	-- Validate the complete batch before executing the first local tool.
	for index = 1, call_count do
		local tc = message.tool_calls[index]
		if type(tc) ~= "table" or type(tc["function"]) ~= "table" then
			return nil, nil, nil, false, build_error(self, "parse_error",
				"OpenAI returned an invalid Function Calling block.")
		end
		local call_id = tostring(tc.id or "")
		local name = tostring(tc["function"].name or "")
		if #call_id == 0 or #name == 0 then
			return nil, nil, nil, false, build_error(self, "parse_error",
				"OpenAI returned an incomplete Function Calling block.",
				"tool_call_id=" .. call_id .. " name=" .. name)
		end
		if batch_ids[call_id] then
			return nil, nil, nil, false, build_error(self, "parse_error",
				"OpenAI returned a duplicate Function Calling ID.",
				"tool_call_id=" .. call_id)
		end
		batch_ids[call_id] = true

		if self._request_tools_enabled == false
			or (type(self._request_tool_names) == "table"
				and next(self._request_tool_names) ~= nil
				and self._request_tool_names[name] ~= true) then
			return nil, nil, nil, false, build_error(self, "unsupported_feature",
				"OpenAI requested a function that was not offered.",
				"tool_call_id=" .. call_id .. " name=" .. name)
		end

		local args, normalized_args, args_error = parse_arguments(self, tc)
		if args_error then
			return nil, nil, nil, false, args_error
		end
		local signature = name .. "\0" .. policy.canonical_object(args)
		local previous_signature = self.processed_tool_call_ids[call_id]
		local cached = self._processed_tool_results[call_id]
		if previous_signature
			and (previous_signature ~= signature or type(cached) ~= "table") then
			return nil, nil, nil, false, build_error(self, "parse_error",
				"OpenAI reused a Function Calling ID with different data.",
				"tool_call_id=" .. call_id)
		end

		prepared[#prepared + 1] = {
			id = call_id,
			name = name,
			args = args,
			normalized_args = normalized_args,
			signature = signature,
			cached = previous_signature and cached or nil,
		}
	end

	if #prepared == 0 then
		return nil, nil, nil, false, build_error(self, "parse_error",
			"OpenAI reported Function Calling without any calls.")
	end

	local authorized, authorization_error =
		policy.authorize_tool_batch(self, prepared)
	if not authorized then
		return nil, nil, nil, false, authorization_error
	end

	local client = require("oasis.local.tool.client")
	local function_call = { service = "OpenAI", tool_outputs = {} }
	local first_output_str = ""
	local speaker = { role = "assistant", content = message.content or "", tool_calls = {} }
	local reboot = false
	local shutdown = false

	for _, call in ipairs(prepared) do
		local output
		if call.cached then
			output = call.cached.output
			reboot = reboot or call.cached.reboot == true
			shutdown = shutdown or call.cached.shutdown == true
		else
			self._tool_side_effects_committed = true
			local result = client.exec_server_tool(
				self:get_format(), call.name, call.args, self._tool_mode_token)
			debug:log("oasis.log", "process",
				"tool exec result (pretty) = " .. tostring(jsonc.stringify(result, true)))
			output = jsonc.stringify(result, false)
			if type(output) ~= "string" then
				output = "null"
			end
			local result_reboot = type(result) == "table" and result.reboot == true
			local result_shutdown = type(result) == "table" and result.shutdown == true
			reboot = reboot or result_reboot
			shutdown = shutdown or result_shutdown
			self.processed_tool_call_ids[call.id] = call.signature
			self._processed_tool_results[call.id] = {
				output = output,
				reboot = result_reboot,
				shutdown = result_shutdown,
			}
		end

		table.insert(function_call.tool_outputs, {
			tool_call_id = call.id,
			output = output,
			name = call.name,
			arguments = call.normalized_args,
		})
		table.insert(speaker.tool_calls, {
			id = call.id,
			type = "function",
			["function"] = {
				name = call.name,
				arguments = call.normalized_args,
			},
		})
		if first_output_str == "" then
			first_output_str = output
		end
	end

	local plain_text_for_console = first_output_str
	function_call.reboot = reboot
    function_call.shutdown = shutdown
	local response_ai_json = jsonc.stringify(function_call, false)
	debug:log("oasis.log", "recv_ai_msg", "response_ai_json = " .. response_ai_json)
	debug:log("oasis.log", "recv_ai_msg",
		string.format("return speaker(tool_calls=%d), tool_outputs=%d",
			#speaker.tool_calls, #function_call.tool_outputs))

	self.chunk_all = ""
	return plain_text_for_console, response_ai_json, speaker, true, nil
end

function M.inject_schema(self, user_msg)
	self._request_tools_enabled = false
	self._request_tool_names = {}
	local is_use_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
	if not (is_use_tool and common.check_function_calling_enabled(self)) then
		return user_msg
	end
	if self.get_format and (self:get_format() == common.ai.format.title) then
		return user_msg
	end

	local client = require("oasis.local.tool.client")
	local schema = client.get_function_call_schema() or {}

	user_msg["tools"] = {}
	for _, tool_def in ipairs(schema) do
		local name = tostring(tool_def.name or "")
		table.insert(user_msg["tools"], {
			type = "function",
			["function"] = {
				name = name,
				description = tool_def.description or "",
				parameters = tool_def.parameters
			}
		})
		self._request_tool_names[name] = true
	end
	if #user_msg["tools"] > 0 then
		user_msg["tool_choice"] = "auto"
		self._request_tools_enabled = true
	else
		user_msg["tool_choice"] = nil
	end
	return user_msg
end

-----------------------------------
-- Convert Function Calling Data --
-----------------------------------
function M.convert_tool_result(chat, speaker, msg)

	debug:log("oasis.log", "convert_tool_result", "Processing tool message")
	if (not speaker.content) or (#tostring(speaker.content) == 0) then
		debug:log("oasis.log", "convert_tool_result", string.format("No tool content, returning false"))
		return false
	end

	msg.name = speaker.name
	msg.content = speaker.content
	msg.tool_call_id = speaker.tool_call_id  -- OpenAI tool id requirement

	debug:log("oasis.log", "convert_tool_result", string.format("append TOOL msg: name=%s, len=%d", tostring(msg.name or ""), (msg.content and #tostring(msg.content)) or 0))

	-- Point: Do not remove  from the  block (to preserve order).
	-- If tool call information is unnecessary, handle it on the Lua script side for each AI service.

	table.insert(chat.messages, msg)
	debug:log("oasis.log", "convert_tool_result", "Tool message added, returning true")

	return true
end

function M.convert_tool_call(chat, speaker, msg)
	debug:log("oasis.log", "convert_tool_call", "Processing assistant message with tool_calls")
	local fixed_tool_calls = {}

	for _, tc in ipairs(speaker.tool_calls or {}) do
		local fn = tc["function"] or {}
		fn.arguments = M.serialize_function_arguments(fn.arguments)

		table.insert(fixed_tool_calls, {
			id = tc.id,
			type = "function",
			["function"] = fn
		})
	end

	msg.tool_calls = fixed_tool_calls
	msg.content = speaker.content or ""
	debug:log("oasis.log", "convert_tool_call", string.format(
		"append ASSISTANT msg with tool_calls: count=%d", #msg.tool_calls
	))

	table.insert(chat.messages, msg)
	debug:log("oasis.log", "convert_tool_call", "Assistant message with tool_calls processed, returning true")

	return true
end

return M
