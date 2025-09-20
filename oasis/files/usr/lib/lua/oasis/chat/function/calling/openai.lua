#!/usr/bin/env lua

local jsonc  = require("luci.jsonc")
local common = require("oasis.common")
local uci    = require("luci.model.uci").cursor()
local debug  = require("oasis.chat.debug")
local ous	 = require("oasis.unified.chat.schema")

local M = {}

function M.detect(message)
	if not message or type(message) ~= "table" then
		return false
	end
	if message.tool_calls and type(message.tool_calls) == "table" and #message.tool_calls > 0 then
		local tool = message.tool_calls[1]
		if tool and tool["function"] and type(tool["function"]) == "table" then
			if tool["function"].name and tool["function"].arguments then
				return true
			end
		end
	end
	return false
end

function M.process(self, message)
	if not M.detect(message) then
		return nil
	end

	local is_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
	if not (is_tool and message and message.tool_calls) then
		return nil
	end

	debug:log("oasis.log", "recv_ai_msg", "is_tool (local_tool flag is enabled)")
	local client = require("oasis.local.tool.client")

	local function_call = { service = "OpenAI", tool_outputs = {} }
	local first_output_str = ""
	local speaker = { role = "assistant", tool_calls = {} }
	local reboot = false

	for _, tc in ipairs(message.tool_calls or {}) do
		local func = tc["function"] and tc["function"].name or ""
		local args = {}
		if tc["function"] and tc["function"].arguments then
			args = jsonc.parse(tc["function"].arguments) or {}
		end

		debug:log("oasis.log", "recv_ai_msg", "func = " .. tostring(func) .. " (detected function name)")
		local call_id = tc.id or ""
		if self.processed_tool_call_ids[call_id] then
			debug:log("oasis.log", "recv_ai_msg", "skip duplicate tool_call id = " .. tostring(call_id))
		else
			self.processed_tool_call_ids[call_id] = true
			local result = client.exec_server_tool(self:get_format(), func, args)
			debug:log("oasis.log", "recv_ai_msg", "tool exec result (pretty) = " .. jsonc.stringify(result, true))
			if type(result) == "table" and result.reboot == true then
				reboot = true
			end

			local output = jsonc.stringify(result, false)
			table.insert(function_call.tool_outputs, {
				tool_call_id = tc.id,
				output = output,
				name = func
			})

			table.insert(speaker.tool_calls, {
				id = tc.id,
				type = "function",
				["function"] = {
					name = func,
					arguments = jsonc.stringify(args, false)
				}
			})

			if first_output_str == "" then first_output_str = output end
		end
	end

	local plain_text_for_console = first_output_str
	function_call.reboot = reboot
	local response_ai_json = jsonc.stringify(function_call, false)
	debug:log("oasis.log", "recv_ai_msg", "response_ai_json = " .. response_ai_json)
	debug:log("oasis.log", "recv_ai_msg",
		string.format("return speaker(tool_calls=%d), tool_outputs=%d",
			#speaker.tool_calls, #function_call.tool_outputs))

	self.chunk_all = ""
	return plain_text_for_console, response_ai_json, speaker, true
end

function M.inject_schema(self, user_msg)
	local is_use_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
	if not is_use_tool then
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
		fn.arguments = ous.normalize_arguments(fn.arguments)
		local norm = ous.normalize_arguments(fn.arguments)
		fn.arguments = jsonc.stringify(norm, false)

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