#!/usr/bin/env lua

local jsonc  = require("luci.jsonc")
local common = require("oasis.common")

local M = {}

local phase_label = {
    request_creation = "Request creation",
    http_request = "HTTP communication",
    api_response = "AI service response",
    response_parse = "Response parsing",
    function_calling = "Function Calling",
    tool_execution = "Tool execution",
    title_generation = "Title generation",
    internal = "Internal processing",
}

local kind_label = {
    request_error = "request error",
    connection_error = "connection error",
    timeout = "timeout",
    api_error = "API error",
    parse_error = "parse error",
    unsupported_feature = "unsupported feature",
    tool_error = "tool error",
    title_error = "title generation error",
    internal_error = "internal error",
    empty_response = "empty response",
}

local function non_empty(value)
    value = tostring(value or "")
    if #value == 0 then
        return nil
    end
    return value
end

local function get_service_cfg(service)
    if type(service) ~= "table" or type(service.get_config) ~= "function" then
        return {}
    end

    local ok, cfg = pcall(function()
        return service:get_config()
    end)

    if ok and type(cfg) == "table" then
        return cfg
    end

    return {}
end

function M.classify_provider_message(message)
    local lower = tostring(message or ""):lower()

    if lower:match("timeout") or lower:match("timed out") then
        return "timeout"
    end

    if lower:match("does not support tools")
        or lower:match("unsupported.*tool")
        or lower:match("tool.*unsupported")
        or lower:match("not support.*tool") then
        return "unsupported_feature"
    end

    if lower:match("connection")
        or lower:match("could not resolve")
        or lower:match("connection refused")
        or lower:match("failed to connect") then
        return "connection_error"
    end

    return "api_error"
end

function M.build(service, opts)
    opts = opts or {}
    local cfg = get_service_cfg(service)
    local provider_message = non_empty(opts.provider_message)
    local detail = non_empty(opts.detail)
    local message = non_empty(opts.message)

    if not message then
        message = provider_message or detail or "Chat request failed."
    end

    local err = {
        status = common.status.error,
        phase = opts.phase or "internal",
        kind = opts.kind or "internal_error",
        message = message,
        provider_message = provider_message,
        detail = detail,
        service = non_empty(opts.service) or non_empty(cfg.service) or "unknown",
        model = non_empty(opts.model) or non_empty(cfg.model) or "unknown",
        can_continue = (opts.can_continue ~= false),
    }

    err.display = M.format(err)

    return err
end

function M.api_error(service, provider_message, opts)
    opts = opts or {}
    local kind = opts.kind or M.classify_provider_message(provider_message)
    local message = opts.message

    if not message then
        if kind == "unsupported_feature" then
            message = "AI service rejected Function Calling or tool use."
        else
            message = "AI service returned an error."
        end
    end

    return M.build(service, {
        phase = opts.phase or "api_response",
        kind = kind,
        message = message,
        provider_message = provider_message,
        detail = opts.detail,
        can_continue = opts.can_continue,
    })
end

function M.format(err)
    if type(err) ~= "table" then
        return tostring(err or "Chat request failed.")
    end

    local lines = {}
    lines[#lines + 1] = tostring(err.message or "Chat request failed.")
    lines[#lines + 1] = "Phase: " .. tostring(phase_label[err.phase] or err.phase or "unknown")
    lines[#lines + 1] = "AI Service: " .. tostring(err.service or "unknown")
    lines[#lines + 1] = "Model: " .. tostring(err.model or "unknown")
    lines[#lines + 1] = "Type: " .. tostring(kind_label[err.kind] or err.kind or "unknown")

    if err.provider_message and #tostring(err.provider_message) > 0 then
        lines[#lines + 1] = "Provider: " .. tostring(err.provider_message)
    end

    if err.detail and #tostring(err.detail) > 0 then
        lines[#lines + 1] = "Detail: " .. tostring(err.detail)
    end

    lines[#lines + 1] = "Chat can continue: " .. ((err.can_continue ~= false) and "yes" or "no")

    return table.concat(lines, "\n")
end

function M.to_response(err)
    if type(err) ~= "table" then
        err = M.build(nil, { message = tostring(err or "Chat request failed.") })
    end

    if not err.display then
        err.display = M.format(err)
    end

    return { error = err }
end

function M.to_json(err)
    return jsonc.stringify(M.to_response(err), false)
end

function M.to_status(err)
    if type(err) ~= "table" then
        err = M.build(nil, { message = tostring(err or "Chat request failed.") })
    end

    return {
        status = common.status.error,
        desc = err.display or M.format(err),
        error = err,
    }
end

return M
