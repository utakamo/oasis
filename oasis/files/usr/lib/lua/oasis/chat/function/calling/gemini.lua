#!/usr/bin/env lua

local jsonc  = require("luci.jsonc")
local common = require("oasis.common")
local uci    = require("luci.model.uci").cursor()
local debug  = require("oasis.chat.debug")
local ous	 = require("oasis.unified.chat.schema")

local M = {}

local function detect_function_call_in_parts(parts)
	if type(parts) ~= "table" then return false end
	for _, p in ipairs(parts) do
		if type(p) == "table" and p.functionCall then
			return true
		end
	end
	return false
end

function M.detect(message)
	if not message or type(message) ~= "table" then
		return false
	end
	-- OpenAI/OLLAMA-like tool_calls structure (fallback)
	if message.tool_calls and type(message.tool_calls) == "table" and #message.tool_calls > 0 then
		local tool = message.tool_calls[1]
		if tool and tool["function"] and type(tool["function"]) == "table" then
			if tool["function"].name and tool["function"].arguments then
				return true
			end
		end
	end
	-- Gemini-like functionCall in candidates[].content.parts[].
	if message.candidates then
		local c = message.candidates[1]
		local parts = c and c.content and c.content.parts or nil
		return detect_function_call_in_parts(parts)
	end
	-- Or direct message.parts pattern
	if message.parts then
		return detect_function_call_in_parts(message.parts)
	end
	-- Or a single functionCall field
	if message.functionCall then
		return true
	end
	return false
end

function M.process(self, message)
	if not M.detect(message) then
		return nil
	end

	local is_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
	if not is_tool then
		return nil
	end

	debug:log("oasis.log", "recv_ai_msg", "is_tool (local_tool flag is enabled) [gemini]")
	local client = require("oasis.local.tool.client")

    local function_call = { service = "Gemini", tool_outputs = {} }
    local first_output_str = ""
    local speaker = { role = "assistant", tool_calls = {} }
    local reboot = false
    local shutdown = false

	local function handle_one_call(name, args, id)
		local call_id = id or ""
		if self and self.processed_tool_call_ids and call_id ~= "" then
			if self.processed_tool_call_ids[call_id] then
				debug:log("oasis.log", "process", "skip duplicate tool_call id = " .. tostring(call_id))
				return
			end
			self.processed_tool_call_ids[call_id] = true
		end
        local result = client.exec_server_tool(self:get_format(), name or "", args or {})
		debug:log("oasis.log", "process", "tool exec result (pretty) [gemini] = " .. jsonc.stringify(result, true))

		if result.reboot then
			debug:log("oasis.log", "process", "result.reboot = true")
			reboot = result.reboot
		end
        if result.shutdown then
            debug:log("oasis.log", "process", "result.shutdown = true")
            shutdown = result.shutdown
        end

		local output = jsonc.stringify(result, false)
		table.insert(function_call.tool_outputs, {
			tool_call_id = call_id,
			output = output,
			name = name or ""
		})
		table.insert(speaker.tool_calls, {
			id = call_id,
			type = "function",
			["function"] = {
				name = name or "",
				arguments = jsonc.stringify(args or {}, false)
			}
		})
		if first_output_str == "" then first_output_str = output end
	end

	-- Case 1: OpenAI-like tool_calls (rare in Gemini path, but keep compatibility)
	if message.tool_calls and type(message.tool_calls) == "table" then
		for _, tc in ipairs(message.tool_calls) do
			local func = tc["function"] and tc["function"].name or ""
			local args = {}
			if tc["function"] and tc["function"].arguments then
				args = jsonc.parse(tc["function"].arguments) or {}
			end
			handle_one_call(func, args, tc.id)
		end
	else
		-- Case 2: Gemini functionCall(s)
		local parts = nil
		if message.candidates then
			local c = message.candidates[1]
			parts = c and c.content and c.content.parts or nil
		elseif message.parts then
			parts = message.parts
		end
		if type(parts) == "table" then
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
					handle_one_call(fname, fargs, f.id)
				end
			end
		end
	end

    local plain_text_for_console = first_output_str
    function_call.reboot = reboot
    function_call.shutdown = shutdown
    local response_ai_json = jsonc.stringify(function_call, false)
	debug:log("oasis.log", "recv_ai_msg", "response_ai_json [gemini] = " .. response_ai_json)
	debug:log("oasis.log", "recv_ai_msg",
		string.format("return speaker(tool_calls=%d), tool_outputs=%d [gemini]",
			#speaker.tool_calls, #function_call.tool_outputs))

	if self then self.chunk_all = "" end
	return plain_text_for_console, response_ai_json, speaker, true
end

function M.inject_schema(self, user_msg)
	-- Gemini attaches tools.functionDeclarations to the GenerateContent body.
	local is_use_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
	if not is_use_tool then
		return user_msg
	end
	if self and self.get_format and (self:get_format() == common.ai.format.title) then
		return user_msg
	end

	local client = require("oasis.local.tool.client")
	local schema = client.get_function_call_schema()

	user_msg = user_msg or {}
	user_msg.tools = user_msg.tools or {}
	local fdecl = {}
	for _, tool_def in ipairs(schema or {}) do
		local params = tool_def.parameters or {}
		table.insert(fdecl, {
			name = tool_def.name,
			description = tool_def.description or "",
			parameters = {
				type = params.type or "object",
				properties = params.properties or {},
				required = params.required or {}
			}
		})
	end
	if #fdecl > 0 then
		user_msg.tools[#user_msg.tools + 1] = { functionDeclarations = fdecl }
	end
	return user_msg
end

-----------------------------------
-- Convert Function Calling Data --
-----------------------------------
function M.convert_tool_result(chat, speaker, msg)

	debug:log("oasis.log", "convert_tool_result[gemini]", "Processing tool message")
	if (not speaker.content) or (#tostring(speaker.content) == 0) then
		debug:log("oasis.log", "convert_tool_result[gemini]", "No tool content, returning false")
		return false
	end

	msg.name = speaker.name
	msg.content = speaker.content
	msg.tool_call_id = speaker.tool_call_id

	debug:log("oasis.log", "convert_tool_result[gemini]", string.format(
		"append TOOL msg: name=%s, len=%d", tostring(msg.name or ""), (msg.content and #tostring(msg.content)) or 0))

	table.insert(chat.messages, msg)
	debug:log("oasis.log", "convert_tool_result[gemini]", "Tool message added, returning true")
	return true
end

function M.convert_tool_call(chat, speaker, msg)
	-- Normalize assistant.tool_calls and append to chat (Gemini path)
	debug:log("oasis.log", "convert_tool_call[gemini]", "Processing assistant message with tool_calls")

	if (not speaker) or (not speaker.tool_calls) or (type(speaker.tool_calls) ~= "table") then
		return
	end

	local fixed_tool_calls = {}
	for _, tc in ipairs(speaker.tool_calls or {}) do
		local fn = tc["function"] or {}
		fn.arguments = ous.normalize_arguments(fn.arguments)
		fn.arguments = jsonc.stringify(fn.arguments, false)

		table.insert(fixed_tool_calls, {
			id = tc.id,
			type = "function",
			["function"] = fn
		})
	end

	msg.tool_calls = fixed_tool_calls
	msg.content = speaker.content or ""

	table.insert(chat.messages, msg)

	debug:log("oasis.log", "convert_tool_call[gemini]", string.format(
		"append ASSISTANT msg with tool_calls: count=%d", #fixed_tool_calls
	))
	return true
end

return M
