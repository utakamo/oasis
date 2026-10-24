local tool_policy = require("oasis.chat.function.calling.policy")
local chat_error = require("oasis.chat.error")
local M = {}
M.MANAGER_TOOLS = {get_tool_list=true, set_tool_enabled=true, set_tool_disabled=true}
local Policy = {}
Policy.__index = Policy
local function error_for(self, code, message, detail)
    local err = chat_error.build(self.service, {phase="tool_execution", kind="tool_error",
        message=message, detail=detail, can_continue=true})
    err.stop_reason = code
    return err
end
local function has_exact_keys(value, expected)
    local count = 0
    for key in pairs(value or {}) do
        if expected[key] ~= true then
            return false
        end
        count = count + 1
    end
    local expected_count = 0
    for _ in pairs(expected) do
        expected_count = expected_count + 1
    end
    return count == expected_count
end

local function validate_manager_arguments(call)
    if call.name == "get_tool_list" then
        if not has_exact_keys(call.arguments, {}) then
            return nil, "get_tool_list arguments must be an empty object"
        end
        return true
    end

    local expected = { server = true, tool = true }
    if not has_exact_keys(call.arguments, expected) then
        return nil, call.name
            .. " arguments must contain exactly server and tool"
    end
    if type(call.arguments.server) ~= "string"
        or not call.arguments.server:match("%S") then
        return nil, call.name .. " server must be a non-empty string"
    end
    if type(call.arguments.tool) ~= "string"
        or not call.arguments.tool:match("%S") then
        return nil, call.name .. " tool must be a non-empty string"
    end
    return true
end


function Policy:validate_batch(calls)
    local managers = 0
    for _, call in ipairs(calls) do
        if M.MANAGER_TOOLS[call.name] then managers = managers + 1 end
    end
    if managers == 0 then return true, false end
    if managers ~= #calls then
        return nil, error_for(self, "mixed_batch", "Tool Search management tools cannot be mixed with normal tools.")
    end
    if #calls ~= 1 then
        return nil, error_for(self, "management_batch", "Tool Search management batches must contain exactly one call.")
    end
    local call = calls[1]
    local ok, why = validate_manager_arguments(call)
    if not ok then
        return nil, error_for(self, "invalid_arguments", "The Tool Search management call has invalid arguments.", why)
    end
    local cursor = require("luci.model.uci").cursor()
    local available, err = require("oasis.agent.runtime").available(cursor)
    if not available then
        return nil, error_for(self, "agent_unavailable", "Agent management tools could not be verified.", err and err.error)
    end
    local state = require("oasis.local.tool.state")
    local snapshot, state_err = state.snapshot(cursor)
    if not snapshot then return nil, error_for(self, "state_error", state_err.error) end
    if not snapshot.auto_mode then
        return nil, error_for(self, "tool_mode_changed", "Tool mode changed. Start a new request.")
    end
    local signature = call.signature
    if call.name == "get_tool_list" then
        local definitions = {}
        for _, tool in ipairs(snapshot.tools) do
            definitions[state.tool_key(tool)] = {definition=state.fingerprint(tool), enabled=tool.enabled}
        end
        signature = signature .. "\0" .. assert(tool_policy.canonical_object(definitions))
    end
    if self.seen[signature] then
        return nil, error_for(self, "repeated_operation", "The Tool Search sequence repeated the same management operation.")
    end
    self.seen[signature] = true
    return true, true
end

function Policy:validate_result(call, field, dense_array_length)
    local output = call.output
    local status, err = field(output, "status"), field(output, "error")
    local failed = err ~= nil and err ~= false and err ~= ""
    if M.MANAGER_TOOLS[call.name] then
        if failed or status ~= "OK" then
            return error_for(self, "tool_error", "A Tool Search management operation reported a failure.", "tool=" .. call.name)
        end
        if call.name == "get_tool_list" and dense_array_length(field(output, "tool")) == nil then
            return error_for(self, "invalid_tool_result", "Tool Search returned a malformed tool list.")
        end
    elseif failed or status == "NG" or status == "ERROR" or status == "error"
        or status == "failed" or field(output, "ok") == false or field(output, "success") == false then
        return error_for(self, "tool_error", "A tool reported a failure.", "tool=" .. call.name)
    end
end

function M.new(service)
    return setmetatable({service=service, seen={}, max_ai_requests=12,
        max_tool_rounds=10, max_tool_calls=24, continue_tools=true,
        stop_on_confirmation=true, stop_on_input=true}, Policy)
end
return M
