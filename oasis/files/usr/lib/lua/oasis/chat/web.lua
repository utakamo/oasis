-- HTTP-independent WebUI request validation and event delivery.
local jsonc      = require("luci.jsonc")
local uci        = require("luci.model.uci").cursor()
local common     = require("oasis.common")
local console    = require("oasis.console")
local chat_main  = require("oasis.chat.main")
local chat_error = require("oasis.chat.error")
local history    = require("oasis.chat.history")
local misc       = require("oasis.chat.misc")
local debug      = require("oasis.chat.debug")

local M = {
    MAX_HTTP_BODY_BYTES = 96 * 1024,
    MAX_PAYLOAD_BYTES = 64 * 1024,
    MAX_MESSAGE_BYTES = 24 * 1024,
}
local allowed_fields = { id = true, message = true, sysmsg_key = true }

function M.request_error(message)
    return chat_error.build(nil, {
        phase = "request_creation", kind = "request_error", message = message,
        can_continue = false,
    })
end

function M.parse_request(payload, content_length)
    local length = tonumber(content_length or "")
    if not length or length <= 0 or length % 1 ~= 0 then
        return nil, M.request_error("The request body is required."), 400
    end
    if length > M.MAX_HTTP_BODY_BYTES then
        return nil, M.request_error("The request body is too large."), 413
    end
    if type(payload) ~= "string" or #payload == 0 then
        return nil, M.request_error("The chat payload is required."), 400
    end
    if #payload > M.MAX_PAYLOAD_BYTES then
        return nil, M.request_error("The chat payload is too large."), 413
    end
    if payload:find("%z") then
        return nil, M.request_error("The chat payload contains an invalid character."), 400
    end
    -- Reject arrays/scalars and excessive nesting before the native JSON parser.
    if not payload:match("^%s*{") then
        return nil, M.request_error("The chat payload must be a JSON object."), 400
    end
    local depth, quoted, escaped = 0, false, false
    for i = 1, #payload do
        local char = payload:sub(i, i)
        if quoted then
            if escaped then escaped = false
            elseif char == "\\" then
                -- luci.jsonc uses NUL-terminated Lua strings on some releases.
                -- Reject this escape before decoding can silently truncate it.
                if payload:sub(i + 1, i + 5) == "u0000" then
                    return nil, M.request_error("The chat payload contains an invalid character."), 400
                end
                escaped = true
            elseif char == '"' then quoted = false end
        elseif char == '"' then quoted = true
        elseif char == "{" or char == "[" then
            depth = depth + 1
            if depth > 8 then
                return nil, M.request_error("The chat payload is too deeply nested."), 400
            end
        elseif char == "}" or char == "]" then
            depth = depth - 1
            if depth == 0 and payload:sub(i + 1):find("%S") then
                return nil, M.request_error("The chat payload contains trailing data."), 400
            end
        end
    end
    local ok, request = pcall(jsonc.parse, payload)
    if not ok or type(request) ~= "table" then
        return nil, M.request_error("The chat payload is not valid JSON."), 400
    end
    for key in pairs(request) do
        if not allowed_fields[key] then
            return nil, M.request_error("The chat payload contains an unsupported field."), 400
        end
    end
    if type(request.id) ~= "string" then
        return nil, M.request_error("The chat ID must be a string."), 400
    end
    if request.id ~= "" then
        if not history.identifier(request.id) then
            return nil, M.request_error("The chat ID is invalid."), 400
        end
        if not common.search_chat_id(request.id) then
            return nil, M.request_error("The requested chat does not exist."), 404
        end
    end
    if type(request.message) ~= "string" or not request.message:find("%S") then
        return nil, M.request_error("The chat message must be a non-empty string."), 400
    end
    if #request.message > M.MAX_MESSAGE_BYTES then
        return nil, M.request_error("The chat message is too large."), 413
    end
    if request.message:find("%z") then
        return nil, M.request_error("The chat message contains an invalid character."), 400
    end
    if request.sysmsg_key == nil then request.sysmsg_key = "" end
    if type(request.sysmsg_key) ~= "string" or #request.sysmsg_key > 128
        or (request.sysmsg_key ~= "" and not request.sysmsg_key:match("^[%w_.%-]+$")) then
        return nil, M.request_error("The system message key is invalid."), 400
    end
    request.cmd = "chat"
    return request
end

local function build_uci_notification(message)
    if type(message) ~= "string" or message == ""
        or not misc.check_file_exist("/usr/lib/lua/oasis/chat/filter.lua")
        or not uci:get_bool(common.db.uci.cfg, common.db.uci.sect.assist, "enable") then
        return nil
    end
    local ok, notification = pcall(function()
        local filter = require("oasis.chat.filter")
        local list = filter.uci_cmd_filter(message)
        if filter.check_uci_list_exist(list) then
            return { uci_list = list, uci_notify = true }
        end
    end)
    if ok then return notification end
    debug:log("oasis.log", "web_chat", "failed to build UCI notification")
end

function M.process(request, emit)
    local disconnected = false
    local function emit_json(value)
        if disconnected then error("Web chat output is closed.") end
        local encoded = type(value) == "string" and value or jsonc.stringify(value, false)
        if type(encoded) ~= "string" or not encoded:match("^%s*{")
            or type(jsonc.parse(encoded)) ~= "table" then
            error("Web chat attempted to emit an invalid JSON event.")
        end
        local ok, result = pcall(emit, encoded .. "\n")
        if not ok or result == false then
            disconnected = true
            error("Web chat output failed.")
        end
    end
    local ok, failure = pcall(function()
        -- An old optional tool package still writes progress directly to stdout.
        -- Refuse mixed installations before any AI request or tool execution.
        if uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
            and misc.check_file_exist("/usr/lib/lua/oasis/local/tool/client.lua") then
            local client = require("oasis.local.tool.client")
            if client.OUTPUT_SINK_VERSION ~= 1 then
                emit_json(chat_error.to_response(M.request_error(
                    "Update oasis-mod-tool before using WebUI tools.")))
                return false
            end
        end
        local info, message, err = console.with_output_sink(emit_json, nil, function()
            return chat_main.output(request)
        end)
        if disconnected then return false end
        if err then
            emit_json(chat_error.to_response(err))
            return false
        end
        if not info and not message then error("Chat processing returned no response.") end
        local notification = build_uci_notification(message)
        if notification then emit_json(notification) end
        if type(info) == "string" and info ~= "" then emit_json(info) end
        return true
    end)
    if ok then return failure end
    debug:log("oasis.log", "web_chat", "chat processing or output failed")
    if not disconnected then
        pcall(emit_json, chat_error.to_response(chat_error.build(nil, {
            phase = "internal", kind = "internal_error",
            message = "Chat processing failed.", can_continue = false,
        })))
    end
    return false
end

return M
