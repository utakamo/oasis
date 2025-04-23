#!/usr/bin/env lua

local jsonc = require("luci.jsonc")
local common = require("oasis.common")

local openai = {}
openai.new = function()

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

            -- When data is received, the processing of this block will be executed.
            -- The received data is stored in a chunk.
            -- In OpenAI, the received chunk data may occasionally be missing as a JSON string.
            -- Therefore, the received data is stored in a buffer until it can be formatted into
            -- data recognizable as a JSON format.

            self.chunk_all = self.chunk_all .. chunk
            local chunk_json = jsonc.parse(self.chunk_all)

            if (not chunk_json) or (type(chunk_json) ~= "table") then
                return "", "", self.recv_ai_msg
            end

            self.chunk_all = ""

            local plain_text_for_console
            local json_text_for_webui

            self.recv_raw_msg.role = chunk_json.choices[1].message.role
            self.recv_raw_msg.message = self.recv_raw_msg.message .. chunk_json.choices[1].message.content

            local reply = {}
            reply.message = {}
            reply.message.role = chunk_json.choices[1].message.role
            reply.message.content = chunk_json.choices[1].message.content

            plain_text_for_console = common.markdown(self.mark, reply.message.content)
            json_text_for_webui = jsonc.stringify(reply, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_ai_msg
            end

            return plain_text_for_console, json_text_for_webui, self.recv_raw_msg
        end

        return obj
end

return openai.new()

--[[
local recv_ai_msg = function(ai, chunk_all, chunk, mark)

    -- When data is received, the processing of this block will be executed.
    -- The received data is stored in a chunk.
    -- In OpenAI, the received chunk data may occasionally be missing as a JSON string.
    -- Therefore, the received data is stored in a buffer until it can be formatted into
    -- data recognizable as a JSON format.

    chunk_all = chunk_all .. chunk
    local chunk_json = jsonc.parse(chunk_all)

    if (not chunk_json) or (type(chunk_json) ~= "table") then
        return "", "", chunk_all
    end

    local plain_text_for_console
    local json_text_for_webui

    ai.role = chunk_json.choices[1].role
    ai.message = ai.message .. chunk_json.choices[1].message.content

    local reply = {}
    reply.message = {}
    reply.message.role = chunk_json.choices[1].role
    reply.message.content = chunk_json.choices[1].message.content

    plain_text_for_console = common.markdown(mark, reply.message.content)
    json_text_for_webui = jsonc.stringify(reply, false)

    if (not plain_text_for_console) or (#plain_text_for_console == 0) then
        return "", "", chunk_all
    end

    return plain_text_for_console, json_text_for_webui, ""
end

return {
    recv_ai_msg = recv_ai_msg,
}
]]