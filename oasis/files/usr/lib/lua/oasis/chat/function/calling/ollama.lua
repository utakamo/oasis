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
	if raw == nil or raw == "" then
		parsed = {}
	elseif type(raw) == "table" then
		parsed = raw
	elseif type(raw) == "string" then
		local trimmed = raw:match("^%s*(.-)%s*$") or ""
		if trimmed:sub(1, 1) ~= "{" or trimmed:sub(-1) ~= "}" then
			return nil, nil, build_error(self, "parse_error",
				"Ollama returned invalid Function Calling arguments.",
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
			"Ollama returned non-object Function Calling arguments.",
			"tool_call_id=" .. tostring(tool_call.id or ""))
	end
	local encoded, encode_error = policy.stringify_object(parsed)
	if not encoded then
		return nil, nil, build_error(self, "parse_error",
			"Ollama returned invalid Function Calling arguments.",
			"tool_call_id=" .. tostring(tool_call.id or "")
				.. " reason=" .. tostring(encode_error))
	end
	return parsed, encoded, nil
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
	if not (is_tool and common.check_function_calling_enabled(self) and message and message.tool_calls) then
		return nil, nil, nil, false, build_error(self, "unsupported_feature",
			"Ollama requested a tool when Function Calling was disabled.")
	end

	debug:log("oasis.log", "recv_ai_msg", "is_tool (local_tool flag is enabled)")
	local prepared = {}
	local batch_ids = {}
	self.processed_tool_call_ids = self.processed_tool_call_ids or {}
	self._processed_tool_results = self._processed_tool_results or {}
	local call_count = policy.dense_array_length(message.tool_calls)
	if call_count == nil then
		return nil, nil, nil, false, build_error(self, "parse_error",
			"Ollama returned a sparse or invalid Function Calling batch.")
	end

	-- Validate and authorize the complete batch before the first execution.
	for index = 1, call_count do
		local tc = message.tool_calls[index]
		if type(tc) ~= "table" or type(tc["function"]) ~= "table" then
			return nil, nil, nil, false, build_error(self, "parse_error",
				"Ollama returned an invalid Function Calling block.")
		end
		local call_id = tostring(tc.id or "")
		local name = tostring(tc["function"].name or "")
		if #name == 0 then
			return nil, nil, nil, false, build_error(self, "parse_error",
				"Ollama returned an incomplete Function Calling block.")
		end
		if #call_id > 0 then
			if batch_ids[call_id] then
				return nil, nil, nil, false, build_error(self, "parse_error",
					"Ollama returned a duplicate Function Calling ID.",
					"tool_call_id=" .. call_id)
			end
			batch_ids[call_id] = true
		end

		if self._request_tools_enabled == false
			or (type(self._request_tool_names) == "table"
				and next(self._request_tool_names) ~= nil
				and self._request_tool_names[name] ~= true) then
			return nil, nil, nil, false, build_error(self, "unsupported_feature",
				"Ollama requested a function that was not offered.",
				"tool_call_id=" .. call_id .. " name=" .. name)
		end

		local args, normalized_args, arguments_error =
			parse_arguments(self, tc)
		if arguments_error then
			return nil, nil, nil, false, arguments_error
		end
		local signature = name .. "\0" .. policy.canonical_object(args)
		local previous_signature = #call_id > 0
			and self.processed_tool_call_ids[call_id] or nil
		local cached = #call_id > 0
			and self._processed_tool_results[call_id] or nil
		if previous_signature
			and (previous_signature ~= signature or type(cached) ~= "table") then
			return nil, nil, nil, false, build_error(self, "parse_error",
				"Ollama reused a Function Calling ID with different data.",
				"tool_call_id=" .. call_id)
		end

		prepared[#prepared + 1] = {
			id = #call_id > 0 and call_id or nil,
			name = name,
			args = args,
			normalized_args = normalized_args,
			signature = signature,
			type = tc.type or "function",
			cached = previous_signature and cached or nil,
		}
	end

	if #prepared == 0 then
		return nil, nil, nil, false, build_error(self, "parse_error",
			"Ollama reported Function Calling without any calls.")
	end

	local authorized, authorization_error =
		policy.authorize_tool_batch(self, prepared)
	if not authorized then
		return nil, nil, nil, false, authorization_error
	end

	local client = require("oasis.local.tool.client")
	local function_call = { service = "Ollama", tool_outputs = {} }
	local first_output_str = ""
	local speaker = {
		role = message.role or common.role.assistant,
		content = tostring(message.content or ""),
		tool_calls = {},
	}
	if message.thinking and #tostring(message.thinking) > 0 then
		speaker.thinking = tostring(message.thinking)
	end
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
			if call.id then
				self.processed_tool_call_ids[call.id] = call.signature
				self._processed_tool_results[call.id] = {
					output = output,
					reboot = result_reboot,
					shutdown = result_shutdown,
				}
			end
		end

		table.insert(function_call.tool_outputs, {
			tool_call_id = call.id,
			output = output,
			name = call.name,
			arguments = call.normalized_args,
		})
		table.insert(speaker.tool_calls, {
			id = call.id,
			type = call.type,
			["function"] = {
				name = call.name,
				arguments = call.args,
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
	local is_use_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
	if not (is_use_tool and common.check_function_calling_enabled(self)) then
		return user_msg
	end
	if self.get_format and (self:get_format() == common.ai.format.title) then
		return user_msg
	end

	local client = require("oasis.local.tool.client")
	local schema = client.get_function_call_schema()

	user_msg["tools"] = {}
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
	user_msg["tool_choice"] = "auto"
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

	local tool_name = speaker.tool_name or speaker.name
	msg.name = tool_name
	msg.tool_name = tool_name
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
--[[
	Ollama tool calls are accumulated across the complete response stream and
	inserted by service/ollama.lua immediately before the tool-result messages.
	Keep this generic hook as a no-op to avoid inserting the same assistant
	tool-call message twice.
]]
	return
end

return M
