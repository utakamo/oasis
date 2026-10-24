local jsonc = require("luci.jsonc")
local policy = require("oasis.chat.function.calling.policy")
local form = require("oasis.ui.form")
local M = {}
local pending

function M.begin() pending = {} end

local function tool_identity(tool)
    local identity = {}
    for key, value in pairs(tool) do
        -- Saved manual selection is not the effective permission in Agent
        -- mode. Keep effective enable/conflict and all definition fields.
        if key ~= "manual_enable" then identity[key] = value end
    end
    return policy.canonical_object(identity)
end

-- Called only at the actual local ubus execution boundary. These records are
-- process-local and cannot be supplied by an AI or a returned JSON field.
function M.capture(tool, method, output, token, arguments)
    if not pending or type(output) ~= "table" or output.ui_action == nil then return end
    local encoded = jsonc.stringify(output, false)
    local copy = jsonc.parse(encoded)
    local fingerprint = assert(tool_identity(tool), "Invalid UI tool identity")
    local signature = assert(policy.canonical_object(copy), "Invalid UI tool result")
    pending[#pending + 1] = {
        name = tool.name, server = tool.server, method = method,
        fingerprint = fingerprint, token = token,
        action = copy.ui_action, output = signature,
        arguments = jsonc.parse(jsonc.stringify(arguments or {}, false)),
    }
end

local function still_authorized(request)
    local state = require("oasis.local.tool.state")
    local cursor = require("luci.model.uci").cursor()
    local snapshot = state.snapshot(cursor, request.token)
    if not snapshot then return false end
    local found = 0
    for _, tool in ipairs(snapshot.tools) do
        if tool.name == request.name then
            found = found + 1
            if not tool.enabled or tool_identity(tool) ~= request.fingerprint then return false end
        end
    end
    return found == 1
end

local function perform(request, entries, terminal)
    if not still_authorized(request) then return "failed", "Tool permission or definition changed; request discarded." end
    local handler, err = require("oasis.ui.registry").resolve(entries, request.action, request)
    if not handler then return "failed", err end
    local state, step = handler.prepare(request.action, { arguments = request.arguments })
    if not state then return "failed", step or "The form could not be prepared." end
    local summary = {}
    for _ = 1, 64 do
        if type(step) ~= "table" then return "failed", "Invalid handler response." end
        if step.failed then return "failed", step.error or "The form could not continue." end
        if step.error then form.validation_error(terminal, step.error) end
        if step.ready == true then
            form.review(summary, terminal)
            if not form.confirm(terminal) then return "cancelled", "Cancelled. This form was not applied." end
            if not still_authorized(request) then return "failed", "Tool permission or definition changed; request discarded." end
            request.applying = true
            local result = handler.apply(state)
            if type(result) ~= "table" then return "failed", "Invalid apply result; verify the current settings." end
            if result.ok then return "applied", "Changes applied." end
            local error_info = result.error
            local message = type(error_info) == "table" and error_info.message or "The settings could not be applied."
            if result.saved then message = "Settings saved. " .. message end
            return "failed", message
        end
        local values, review = form.read(step.form, terminal)
        if not values then
            return review == "cancelled" and "cancelled" or "failed",
                review == "cancelled" and "Cancelled. This form was not applied." or review
        end
        local next_step = handler.advance(state, values)
        if type(next_step) ~= "table" then return "failed", "Invalid handler response." end
        if not next_step.retry then
            summary[#summary + 1] = { title = step.form.title, lines = review }
        end
        step = next_step
    end
    return "failed", "Form step limit reached. This form was not applied."
end

function M.finish(result, terminal)
    terminal = terminal or require("oasis.console")
    local captured = pending or {}
    pending = nil
    if #captured == 0 then return 0 end
    if not result or not result.ok then
        form.status(terminal, "cancelled", "Input requests discarded because the AI turn failed. No form changes applied.")
        return 0
    end
    local ok, info = pcall(jsonc.parse, result.tool_info or "")
    if not ok or type(info) ~= "table" or type(info.tool_outputs) ~= "table" then
        form.status(terminal, "failed", "Missing validated tool results.")
        return 1
    end
    local queue, seen = {}, {}
    for _, output in ipairs(info.tool_outputs) do
        local id = output.tool_call_id or output.id
        local value = output.output
        if type(value) == "string" then value = jsonc.parse(value) end
        if type(value) == "table" and value.ui_action ~= nil then
            if type(id) ~= "string" or id == "" then return 1 end
            local signature = output.name .. ":" .. (policy.canonical_object(value) or "")
            if seen[id] and seen[id] ~= signature then return 1 end
            if not seen[id] then
                seen[id] = signature
                for _, request in ipairs(captured) do
                    if not request.used and output.name == request.name
                        and policy.canonical_object(value) == request.output then
                        request.used = true
                        queue[#queue + 1] = request
                        break
                    end
                end
            end
        end
    end
    for _, request in ipairs(captured) do
        if not request.used then
            form.status(terminal, "failed", "Input request did not match validated tool results.")
            return 1
        end
    end
    if not terminal.is_interactive() then
        form.status(terminal, "input_required", "Run this request in an interactive terminal. No form changes applied.")
        return 2
    end
    local entries, err = require("oasis.ui.registry").load()
    if not entries then form.status(terminal, "failed", err); return 1 end
    local exit_code = 0
    for _, request in ipairs(queue) do
        local success, status, message = pcall(perform, request, entries, terminal)
        if not success then
            -- Exception strings may contain entered values; never print them.
            form.status(terminal, "failed", request.applying
                and "Application failed unexpectedly; verify the current settings."
                or "Input processing was interrupted. This form was not applied.")
            return 1
        end
        form.status(terminal, status, message)
        if status == "cancelled" then return 1 end
        if status ~= "applied" then exit_code = 1 end
    end
    return exit_code
end

return M
