#!/usr/bin/env lua

local jsonc     = require("luci.jsonc")
local common    = require("oasis.common")
local uci       = require("luci.model.uci").cursor()
local util      = require("luci.util")
local datactrl  = require("oasis.chat.datactrl")
local misc      = require("oasis.chat.misc")
local debug     = require("oasis.chat.debug")
local calling   = require("oasis.chat.function.calling.ollama")
local ous       = require("oasis.unified.chat.schema")

local ollama ={}
ollama.new = function()

        local obj = {}
        obj.mark = {}
        obj.recv_raw_msg = {}
        obj.recv_raw_msg.role = common.role.unknown
        obj.recv_raw_msg.message = ""
        obj.cfg = nil
        obj.format = nil
        obj.tool = false
        obj._reboot_required = false

        obj.initialize = function(self, arg, format)
            self.cfg =  datactrl.get_ai_service_cfg(arg, {format = format})
            self.format = format
        end

        local function is_model_tool_capable(model)
            local name = tostring(model or ""):lower()
            if #name == 0 then return false end
            local markers = {
                "llama3", "llama 3", -- llama3.x family
                "qwen", "qwen2", "qwen3",
                "mistral", "mixtral",
                "deepseek",
                "phi4", "phi-4",
                "firefunction",
                "gpt-oss",
                "nemotron",
                "granite",
                "hermes",
                "smollm",
                "qwq",
                "magistral",
                "cogito",
                "command-r"
            }
            for _, m in ipairs(markers) do
                if name:find(m, 1, true) then return true end
            end
            return false
        end

        obj.init_msg_buffer = function(self)
            self.recv_raw_msg.role = common.role.unknown
            self.recv_raw_msg.message = ""
        end

        obj.set_chat_id = function(self, id)
            self.cfg.id = id
        end

        -- [ADD] helper: parse chunk to JSON (returns nil on invalid input)
		obj._parse_chunk = function(self, chunk)
			local chunk_json = jsonc.parse(chunk)
			if (not chunk_json) or (type(chunk_json) ~= "table") then
				return nil
			end
			return chunk_json
		end

        -- [ADD] helper: detect presence of tool_calls (returns message if present)
		obj._has_tool_calls = function(self, chunk_json)
			if chunk_json.message and chunk_json.message.tool_calls
				and type(chunk_json.message.tool_calls) == "table"
				and #chunk_json.message.tool_calls > 0 then
				return chunk_json.message
			end
			return nil
		end

        -- [ADD] helper: execute tool calls when local_tool is enabled (return values and order preserved)
		obj._process_tool_calls = function(self, message)
			local is_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
			if not is_tool then
				return nil
			end

			local client = require("oasis.local.tool.client")
			local function_call = { service = "Ollama", tool_outputs = {} }
			local first_output_str = ""
			local speaker = { role = "assistant", tool_calls = {} }

			for _, tc in ipairs(message.tool_calls or {}) do
				local func = tc["function"] and tc["function"].name or ""
				local args = {}
				if tc["function"] and tc["function"].arguments then
					args = tc["function"].arguments
					if type(args) == "string" then
						args = jsonc.parse(args) or {}
					end
				end

				debug:log("oasis.log", "recv_ai_msg", "ollama func = " .. tostring(func))
				local result = client.exec_server_tool(self:get_format(), func, args)
				debug:log("oasis.log", "recv_ai_msg", jsonc.stringify(result, true))

				local output = jsonc.stringify(result, false)
				table.insert(function_call.tool_outputs, {
					output = output,
					name = func
				})

				local tool_id = nil
				table.insert(speaker.tool_calls, {
					id = tool_id,
					type = "function",
					["function"] = {
						name = func,
						arguments = jsonc.stringify(args, false)
					}
				})

				if first_output_str == "" then first_output_str = output end
			end

			local plain_text_for_console = first_output_str
			local response_ai_json = jsonc.stringify(function_call, false)
			debug:log("oasis.log", "recv_ai_msg", response_ai_json)
			return plain_text_for_console, response_ai_json, speaker, true
		end

        -- [ADD] helper: validate message structure
		obj._is_valid_message = function(self, chunk_json)
			if (not chunk_json.message)
				or (not chunk_json.message.role)
				or (chunk_json.message.content == nil) then
				return false
			end
			return true
		end

        -- [ADD] helper: update buffer and build display text / AI JSON
		obj._build_text_response = function(self, chunk_json)
			self.recv_raw_msg.role = chunk_json.message.role
			self.recv_raw_msg.message = self.recv_raw_msg.message .. tostring(chunk_json.message.content)

			local plain_text_for_console = misc.markdown(self.mark, tostring(chunk_json.message.content))
			local response_ai_json = jsonc.stringify(chunk_json, false)

			if (not plain_text_for_console) or (#plain_text_for_console == 0) then
				return "", "", self.recv_raw_msg, false
			end

			return plain_text_for_console, response_ai_json, self.recv_raw_msg, false
		end

        -- [REPLACE] recv_ai_msg (I/O and log order preserved)
		obj.recv_ai_msg = function(self, chunk)

			-- Log raw response from Ollama for troubleshooting
			debug:log("oasis.log", "recv_ai_msg", tostring(chunk))

            -- Parse JSON (on failure, behave silently as before)
			local chunk_json = self:_parse_chunk(chunk)
			if not chunk_json then
				return "", "", self.recv_raw_msg, false
			end

            -- Raw chunk log after successful JSON parsing (unchanged)
			debug:log("oasis.log", "recv_ai_msg", chunk)

            -- Tool calls (same conditions and order as before)
			do
				local msg_for_tools = self:_has_tool_calls(chunk_json)
				if msg_for_tools then
					local p, j, s, u = self:_process_tool_calls(msg_for_tools)
					if p ~= nil then
						return p, j, s, u
					end
				end
			end

            -- If message structure invalid, return as before
			if not self:_is_valid_message(chunk_json) then
				return "", "", self.recv_raw_msg, false
			end

            -- Normal response (unchanged)
			return self:_build_text_response(chunk_json)
		end

        obj.append_chat_data = function(self, chat)
            -- debug:log("oasis.log", "id = " .. self.cfg.id)
            -- debug:log("oasis.log", chat.messages[#chat.messages - 1].role)
            -- debug:log("oasis.log", chat.messages[#chat.messages - 1].content)
            -- debug:log("oasis.log", chat.messages[#chat.messages].role)
            -- debug:log("oasis.log", chat.messages[#chat.messages].content)
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

        obj.convert_schema = function(self, user_msg)
            local is_use_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
            local model = (self.cfg and self.cfg.model) or ""
            local supports_tool = is_model_tool_capable(model)

            -- When role:tool is present, it indicates that results are sent to AI
            -- Here we don't include the tools field (it's okay to include it, in which case tool execution can be done for failures)
            local last = user_msg.messages and user_msg.messages[#user_msg.messages]
            if last and last.role == "tool" then
                user_msg.tool_choice = nil
                user_msg.tools = nil
                local user_msg_json = jsonc.stringify(user_msg, false)
                return user_msg_json
            end

            -- Inject tools schema for function calling (Ollama)
            if is_use_tool and supports_tool and (self:get_format() ~= common.ai.format.title) then
                local client = require("oasis.local.tool.client")
                local schema = client.get_function_call_schema()

                user_msg["tools"] = {}
                -- Prefer non-streaming single JSON response for function calling
                user_msg["stream"] = false

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
            end

            local user_msg_json = jsonc.stringify(user_msg, false)
            user_msg_json = user_msg_json:gsub('"properties"%s*:%s*%[%]', '"properties":{}')

            debug:log("oasis.log", "prepare_post_to_server", user_msg_json)

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

            easy:setopt_httpheader({
                "Content-Type: application/json",
                "Authorization: Bearer " .. self.cfg.api_key
            })

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
                -- Insert assistant message with tool_calls first to satisfy Ollama sequencing
                local tool_calls = {}

                for _, t in ipairs(tool_info_tbl.tool_outputs) do
                    local tool_id = t.id or ""
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
                    debug:log(
                        "oasis.log",
                        "handle_tool_output",
                        string.format(
                            "[output] insert assistant tool_calls: count=%d",
                            #tool_calls
                        )
                    )
                    ous.setup_msg(self, chat, { role = common.role.assistant, tool_calls = tool_calls, content = "" })
                end

                for _, t in ipairs(tool_info_tbl.tool_outputs) do

                    local content = t.output
                    if type(content) ~= "string" then
                        content = jsonc.stringify(content, false)
                    end

                    debug:log(
                        "oasis.log",
                        "handle_tool_output",
                        string.format(
                            "[output] tool msg: id=%s, name=%s, len=%d",
                            tostring(t.id or ""),
                            tostring(t.name or ""),
                            tonumber((content and #content) or 0)
                        )
                    )

                    ous.setup_msg(self, chat, {
                        role = "tool",
                        -- tool_call_id = t.id,
                        name = t.name,
                        content = content
                    })
                end

                local chat_json = jsonc.stringify(chat, true)

                debug:log("oasis.log", "handle_tool_output", chat_json)

                return true
            end
            return false
        end

        return obj
end

return ollama.new()
