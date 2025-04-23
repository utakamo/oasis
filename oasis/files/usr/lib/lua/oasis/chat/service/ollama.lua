#!/usr/bin/env lua

local jsonc = require("luci.jsonc")
local common = require("oasis.common")

local ollama ={}
ollama.new = function()

        local obj = {}
        obj.mark = {}
        obj.recv_raw_msg = {}
        obj.recv_raw_msg.role = common.role.unknown
        obj.recv_raw_msg.message = ""

        obj.reset = function(self)
            self.recv_raw_msg.role = common.role.unknown
            self.recv_raw_msg.message = ""
        end

        obj.recv_ai_msg = function(self, chunk)

            local chunk_json = jsonc.parse(chunk)

            if (not chunk_json) or (type(chunk_json) ~= "table") then
                return "", "", self.recv_raw_msg
            end

            self.recv_raw_msg.role = chunk_json.message.role
            self.recv_raw_msg.message = self.recv_raw_msg.message .. chunk_json.message.content

            local plain_text_for_console = common.markdown(self.mark, chunk_json.message.content)
            local json_text_for_webui = jsonc.stringify(chunk_json, false)

            if (not plain_text_for_console) or (#plain_text_for_console == 0) then
                return "", "", self.recv_raw_msg
            end

            return plain_text_for_console, json_text_for_webui, self.recv_raw_msg
        end

        return obj
end

return ollama.new()

--[[
local recv_ai_msg = function(ai, chunk_all, chunk, mark)

    chunk_all = chunk_all .. chunk
    local chunk_json = jsonc.parse(chunk_all)

    if (not chunk_json) or (type(chunk_json) ~= "table") then
        return "", "", chunk_all
    end

    ai.role = chunk_json.message.role
    ai.message = ai.message .. chunk_json.message.content

    local plain_text_for_console = common.markdown(mark, chunk_json.message.content)
    local json_text_for_webui = jsonc.stringify(chunk_json, false)

    if (not plain_text_for_console) or (#plain_text_for_console == 0) then
        return "", "", chunk_all
    end

    return plain_text_for_console, json_text_for_webui, ""
end

return {
    recv_ai_msg = recv_ai_msg,
}
]]