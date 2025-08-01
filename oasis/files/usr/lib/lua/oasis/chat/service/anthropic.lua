#!/usr/bin/env lua

local jsonc     = require("luci.jsonc")
local common    = require("oasis.common")
local uci       = require("luci.model.uci").cursor()
local util      = require("luci.util")
local datactrl  = require("oasis.chat.datactrl")
local misc      = require("oasis.chat.misc")

local anthropic = {}
anthropic.new = function()

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
            local sysmsg = common.load_conf_file(spath)

            if (self.format == common.ai.format.chat) and ((not self.cfg.id) or (#self.cfg.id == 0)) then
                table.insert(chat.messages, 1, {
                    role = common.role.system,
                    content = string.gsub(sysmsg.default.chat, "\\n", "\n")
                })
            elseif ((self.format == common.ai.format.output) or (self.format == common.ai.format.rpc_output)) and ((not self.cfg.id) or (#self.cfg.id == 0)) then
                table.insert(chat.messages, 1, {
                    role = common.role.system,
                    content = string.gsub(sysmsg.default.output, "\\n", "\n")
                })
            elseif self.format == common.ai.format.prompt then
                table.insert(chat.messages, 1, {
                    role = common.role.system,
                    content = string.gsub(sysmsg.default.prompt, "\\n", "\n")
                })
            elseif self.format == common.ai.format.call then
                table.insert(chat.messages, 1, {
                    role = common.role.system,
                    content = string.gsub(sysmsg.default.call, "\\n", "\n")
                })
            end
        end

        obj.setup_msg = function(chat, speaker)

            if (not speaker.role)
                or (speaker.role ~= common.role.unknown)
                or (not speaker.message)
                or (#speaker.message == 0) then
                return false
            end

            chat.messages[#chat.messages + 1] = {}
            chat.messages[#chat.messages].role = speaker.role
            chat.messages[#chat.messages].content = speaker.message

            return true
        end

        obj.recv_ai_msg = function(self, chunk)

            self.chunk_all = self.chunk_all .. chunk
            local chunk_json = jsonc.parse(self.chunk_all)

            if (not chunk_json) or (type(chunk_json) ~= "table") then
                return "", "", self.recv_ai_msg
            end

            self.chunk_all = ""

            local plain_text_for_console
            local json_text_for_webui

            self.recv_raw_msg.role = chunk_json.role
            self.recv_raw_msg.message = chunk_json.content.text

            local reply = {}
            reply.message = {}
            reply.message.role = chunk_json.role
            reply.message.content = chunk_json.content.text

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

        obj.config = function(self)
            return self.cfg
        end

        obj.format = function(self)
            return self.format
        end

        return obj
end

return anthropic.new()
