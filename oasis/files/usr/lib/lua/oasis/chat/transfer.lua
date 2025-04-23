#!/usr/bin/env lua

-- local uci = require("luci.model.uci").cursor()
local curl = require("cURL.safe")
local ollama = require("oasis.chat.service.ollama")
local openai = require("oasis.chat.service.openai")
local anthropic = require("oasis.chat.service.anthropic")
local gemini = require("oasis.chat.service.gemini")
local common = require("oasis.common")

local ai = {}
ai.service = {}
ai.service.ollama       = "ollama"
ai.service.openai       = "openai"
ai.service.anthropic    = "anthropic"
ai.service.gemini      = "gemini"

ai.format = {}
ai.format.chat      = "chat"
ai.format.prompt    = "prompt"
ai.format.call      = "call"
ai.format.output    = "output"

local post_to_server = function(cfg, user_msg_json, callback)
    local easy = curl.easy()
    -- os.execute("echo " .. cfg.endpoint .. " /tmp/refactor.log")
    easy:setopt_url(cfg.endpoint)
    easy:setopt_writefunction(callback)
    -- ollama or openai
    if cfg.api_key and (type(cfg.api_key) == "string") and (#cfg.api_key > 0) then
        if (cfg.service == common.ai.service.ollama.name)
            or (cfg.service == common.ai.service.openai.name)
            or (cfg.service == common.ai.service.anthropic.name) then

            easy:setopt_httpheader({
                "Content-Type: application/json",
                "Authorization: Bearer " .. cfg.api_key
            })

        elseif cfg.service == common.ai.service.gemini.name then
            easy:setopt_httpheader({
                "Content-Type: application/json",
                "Authorization: Bearer " .. cfg.api_key
            })
        end
    end
    easy:setopt_httppost(curl.form())
    easy:setopt_postfields(user_msg_json)
    local success = easy:perform()

    if not success then
        print("\27[31m" .. "Error" .. "\27[0m")
    end

    easy:close()
end

local get_to_server = function(url, callback)
    local easy = curl.easy()
    easy:setopt_url(url)
    easy:setopt_writefunction(callback)
    easy:perform()
    easy:close()
end

local send_user_msg = function(cfg, format, user_msg_json)

    local recv_raw_msg

    ollama:reset()
    openai:reset()
    anthropic:reset()
    gemini:reset()

    -- Post
    post_to_server(cfg, user_msg_json, function(chunk)

        local text_for_console
        local text_for_webui

        if cfg.service == common.ai.service.ollama.name then
            text_for_console, text_for_webui, recv_raw_msg = ollama:recv_ai_msg(chunk)
        elseif cfg.service == common.ai.service.openai.name then
            text_for_console, text_for_webui, recv_raw_msg = openai:recv_ai_msg(chunk)
        elseif cfg.service == common.ai.service.anthropic.name then
            text_for_console, text_for_webui, recv_raw_msg = anthropic:recv_ai_msg(chunk)
        elseif cfg.service == common.ai.service.gemini.name then
            text_for_console, text_for_webui, recv_raw_msg = gemini:recv_ai_msg(chunk)
        end

        -- output console
        if (format == ai.format.chat) or (format == ai.format.prompt) or (format == ai.format.call) then
            if (text_for_console) and (#text_for_console) > 0 then
                io.write(text_for_console)
                io.flush()
            end

        -- output webui
        elseif (format == ai.format.output) then
            if (text_for_webui) and (#text_for_webui > 0) then
                io.write(text_for_webui)
                io.flush()
            end
        end
    end)

    return recv_raw_msg
end

return {
    ai = ai,
    post_to_server = post_to_server,
    get_to_server = get_to_server,
    send_user_msg = send_user_msg,
}