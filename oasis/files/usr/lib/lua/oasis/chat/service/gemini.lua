#!/usr/bin/env lua

local jsonc = require("luci.jsonc")
local common = require("oasis.common")

local gemini ={}
gemini.new = function()

        local obj = {}
        obj.chunk_all = ""
        obj.mark = {}
        obj.recv_raw_msg = {}
        obj.recv_raw_msg.role = common.role.unknown
        obj.recv_raw_msg.message = ""

        obj.reset = function(self)
            self.recv_raw_msg.role = common.role.unknown
            self.recv_raw_msg.message = ""
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

            self.recv_raw_msg.role = chunk_json.candidates[1].content.role
            self.recv_raw_msg.message = chunk_json.candidates[1].content.parts.text

            local reply = {}
            reply.message = {}
            reply.message.role = chunk_json.candidates[1].content.role
            reply.message.content = chunk_json.candidates[1].content.parts.text

            plain_text_for_console = common.markdown(self.mark, reply.message.content)
            json_text_for_webui = jsonc.stringify(reply, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_ai_msg
            end

            return plain_text_for_console, json_text_for_webui, self.recv_raw_msg
        end

        return obj
end

return gemini.new()

--[[
local recv_ai_msg = function(ai, chunk_all, chunk, mark)

    local chunk_json
    chunk_all = chunk_all .. chunk
    chunk_json = jsonc.parse(chunk_all)

    if not chunk_json then
        return ""
    end

    if type(chunk_json) ~= "table" then
        return ""
    end

    ai.role = chunk_json.candidates[1].content.role
    ai.message = chunk_json.candidates[1].content.parts.text
    return common:markdown(mark, chunk_json.message.content)
end

return {
    recv_ai_msg = recv_ai_msg,
}
]]