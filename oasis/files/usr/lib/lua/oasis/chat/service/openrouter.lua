#!/usr/bin/env lua

local jsonc     = require("luci.jsonc")
local common    = require("oasis.common")
local uci       = require("luci.model.uci").cursor()
local util      = require("luci.util")
local datactrl  = require("oasis.chat.datactrl")
local misc      = require("oasis.chat.misc")
-- local debug     = require("oasis.chat.debug")

local openrouter = {}
openrouter.new = function()

        local obj = {}
        obj.chunk_all = ""
        obj.mark = {}
        obj.recv_raw_msg = {}
        obj.recv_raw_msg.role = common.role.unknown
        obj.recv_raw_msg.message = ""
        obj.cfg = nil
        obj.format = nil

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

        obj.setup_system_msg = function(self, chat)

            local spath = uci:get(common.db.uci.cfg, common.db.uci.sect.role, "path")
            local sysrole = common.load_conf_file(spath)

            -- debug:log("oasis.log", "\n--- [openrouter.lua][setup_system_msg] ---");
            -- debug:log("oasis.log", "format = " .. self.format)

            -- The system message (knowledge) is added to the first message in the chat.
            -- The first message is data that has not been assigned a chat ID.
            if (not self.cfg.id) or (#self.cfg.id == 0) then
                -- System message(rule or knowledge) for chat
                if (self.format == common.ai.format.chat) then
                    table.insert(chat.messages, 1, {
                        role = common.role.system,
                        content = string.gsub(sysrole.default.chat, "\\n", "\n")
                    })
                    return
                end

                if (self.format == common.ai.format.output) then
                    table.insert(chat.messages, 1, {
                        role = common.role.system,
                        content = string.gsub(sysrole[self.cfg.sysmsg_key].chat, "\\n", "\n")
                    })
                    return
                end

                -- System message(rule or knowledge) for creating chat title
                if (self.format == common.ai.format.title) then
                    table.insert(chat.messages, 1, {
                        role = common.role.system,
                        content = string.gsub(sysrole.general.auto_title, "\\n", "\n")
                    })
                    return
                end
            end

            if self.format == common.ai.format.prompt then
                table.insert(chat.messages, 1, {
                    role = common.role.system,
                    content = string.gsub(sysrole.default.prompt, "\\n", "\n")
                })
                return
            end

            if self.format == common.ai.format.call then
                table.insert(chat.messages, 1, {
                    role = common.role.system,
                    content = string.gsub(sysrole.default.call, "\\n", "\n")
                })
                return
            end
        end

        obj.setup_msg = function(self, chat, speaker)
            -- debug:log("oasis.log", "\n--- [openrouter.lua][setup_msg] ---")

            if (not speaker.role)
                or (#speaker.role == 0)
                or (speaker.role == common.role.unknown)
                or (not speaker.message)
                or (#speaker.message == 0) then
                -- debug:log("oasis.log", "false")
                return false
            end

            chat.messages[#chat.messages + 1] = {}
            chat.messages[#chat.messages].role = speaker.role
            chat.messages[#chat.messages].content = speaker.message

            -- debug:dump("oasis.log", chat)

            return true
        end

        obj.recv_ai_msg = function(self, chunk)

            -- debug:log("oasis.log", "\n--- [openrouter.lua][recv_ai_msg] ---")

            -- When data is received, the processing of this block will be executed.
            -- The received data is stored in a chunk.
            -- In openrouter, the received chunk data may occasionally be missing as a JSON string.
            -- Therefore, the received data is stored in a buffer until it can be formatted into
            -- data recognizable as a JSON format.

            self.chunk_all = self.chunk_all .. chunk
            local chunk_json = jsonc.parse(self.chunk_all)

            if (not chunk_json) or (type(chunk_json) ~= "table") then
                return "", "", self.recv_ai_msg
            end

            -- debug:log("oasis.log", self.chunk_all)

            self.chunk_all = ""

            local plain_text_for_console
            local json_text_for_webui

            self.recv_raw_msg.role = chunk_json.choices[1].message.role
            self.recv_raw_msg.message = self.recv_raw_msg.message .. chunk_json.choices[1].message.content

            local reply = {}
            reply.message = {}
            reply.message.role = chunk_json.choices[1].message.role
            reply.message.content = chunk_json.choices[1].message.content

            plain_text_for_console = misc.markdown(self.mark, reply.message.content)
            json_text_for_webui = jsonc.stringify(reply, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_ai_msg
            end

            return plain_text_for_console, json_text_for_webui, self.recv_raw_msg
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

        obj.get_config = function(self)
            return self.cfg
        end

        obj.get_format = function(self)
            return self.format
        end

        return obj
end

return openrouter.new()
