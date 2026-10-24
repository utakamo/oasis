-- Shared mode selection. Loading this module never loads optional packages.
local M = { AGENT_ABI = 1 }

local function cursor(value)
    return value or require("luci.model.uci").cursor()
end

local function failure(code, message)
    return { status = "NG", changed = false, code = code, error = message }
end

function M.function_calling_enabled(uci)
    uci = cursor(uci)
    local ok, value = pcall(function()
        local section = uci:get_first("oasis", "service")
        return section and uci:get("oasis", section, "function_calling")
    end)
    return ok and value == "1"
end

function M.check_function_calling(uci)
    if M.function_calling_enabled(uci) then return true end
    return nil, failure("function_calling_disabled", "The selected AI service has Function Calling disabled.")
end

function M.read(uci)
    uci = cursor(uci)
    local ok, support = pcall(uci.get_all, uci, "oasis", "support")
    if not ok or type(support) ~= "table" then
        return nil, failure("uci_read_failed", "Failed to read the mode configuration.")
    end
    local flag = support.tool_auto or "0"
    local generation = support.tool_auto_generation or "0"
    if (flag ~= "0" and flag ~= "1") or type(generation) ~= "string"
        or not generation:match("^%d+$") or #generation > 12 then
        return nil, failure("invalid_tool_mode", "Invalid mode configuration.")
    end
    return { mode = flag == "1" and "agent" or "normal", auto_mode = flag == "1",
        token = flag .. ":" .. generation, generation = tonumber(generation) }
end

function M.agent_runtime(uci)
    local loaded, runtime = pcall(require, "oasis.agent.runtime")
    if not loaded or type(runtime) ~= "table" then
        return nil, failure("agent_unavailable", "Install or repair oasis-mod-agent to use Agent mode.")
    end
    if runtime.ABI ~= M.AGENT_ABI or type(runtime.available) ~= "function"
        or type(runtime.new_policy) ~= "function" or type(runtime.select_tools) ~= "function"
        or type(runtime.decorate_request) ~= "function" then
        return nil, failure("agent_incompatible", "Update oasis-mod-agent to use Agent mode.")
    end
    local ok, available, err = pcall(runtime.available, cursor(uci))
    if not ok then
        return nil, failure("agent_unavailable", "Agent availability could not be verified.")
    end
    if not available then return nil, err end
    return runtime
end

function M.get_status(uci, options)
    uci = cursor(uci)
    local selected, err = M.read(uci)
    if not selected then return err end
    local runtime, unavailable = M.agent_runtime(uci)
    local allowed, service_error = true, nil
    if options and options.require_function_calling then
        allowed, service_error = M.check_function_calling(uci)
    end
    return { status = "OK", mode = selected.mode, enabled = selected.auto_mode,
        auto_mode = selected.auto_mode, generation = selected.generation, token = selected.token,
        available = runtime ~= nil, can_enable = runtime ~= nil and allowed == true, can_disable = true,
        reason_code = unavailable and unavailable.code,
        reason = unavailable and unavailable.error,
        service_reason_code = service_error and service_error.code }
end

local function stage_mode(uci, selected, name, invalidate_floor)
    local changed = selected.mode ~= name
    if changed or invalidate_floor ~= nil then
        local generation = math.max(selected.generation, tonumber(invalidate_floor) or 0)
        if generation >= 999999999999
            or uci:set("oasis", "support", "tool_auto", name == "agent" and "1" or "0") ~= true
            or uci:set("oasis", "support", "tool_auto_generation",
                string.format("%.0f", generation + 1)) ~= true then
            return failure("uci_set_failed", "Failed to update the mode.")
        end
    end
    return { status = "OK", changed = changed, mode = name,
        auto_mode = name == "agent", enabled = name == "agent" }
end

-- Stage the automatic OFF alongside the service change. The caller holds the
-- mode lock and owns the commit/revert, so both changes succeed together.
function M.reconcile_function_calling(uci)
    if M.function_calling_enabled(uci) then return { status = "OK", changed = false } end
    local selected, err = M.read(uci)
    if not selected then return err end
    return stage_mode(uci, selected, "normal")
end

function M.set_mode(name, uci, expected_token, invalidate_floor, options)
    if name ~= "agent" and name ~= "normal" then
        return failure("invalid_mode", "Mode must be agent or normal.")
    end
    uci = cursor(uci)
    local result, lock_err = require("oasis.mode_lock").with_lock(function()
        local ok, value, code = require("oasis.uci_transaction").run({
            cursor = uci, config = "oasis", label = "Oasis mode",
        }, function(private_uci)
            local selected, err = M.read(private_uci)
            if not selected then return false, err, err.code end
            if expected_token and selected.token ~= expected_token then
                local changed = failure("tool_mode_changed", "Mode changed. Reload its current state.")
                return false, changed, changed.code
            end
            if name == "agent" and invalidate_floor == nil then
                if options and options.require_function_calling then
                    local allowed
                    allowed, err = M.check_function_calling(private_uci)
                    if not allowed then return false, err, err.code end
                end
                local runtime
                runtime, err = M.agent_runtime(private_uci)
                if not runtime then return false, err, err.code end
            end
            local updated = stage_mode(private_uci, selected, name, invalidate_floor)
            return updated.status == "OK", updated, updated.code
        end)
        if type(value) == "table" then return value end
        return failure(code or "uci_transaction_failed", tostring(value or "Failed to save the mode."))
    end)
    return result or failure("mode_lock_failed", lock_err)
end

-- Package setup invalidates requests after install/restore even if the saved
-- mode did not change. The pre-restore floor prevents generation rollback.
function M.invalidate(uci, generation_floor)
    local floor = tostring(generation_floor or "0")
    if not floor:match("^%d+$") or #floor > 12 then
        return failure("invalid_tool_mode", "Invalid pre-restore mode generation.")
    end
    local selected, err = M.read(uci)
    if not selected then return err end
    return M.set_mode(selected.mode, uci, selected.token, tonumber(floor))
end

-- Called only for requests which permit local tools. Text-only and title
-- requests must remain independent of optional modules and mode storage.
function M.resolve_execution(service, uci)
    uci = cursor(uci)
    local selected, err = M.read(uci)
    if not selected then return nil, err end
    if not selected.auto_mode then return { token = selected.token } end
    local runtime
    runtime, err = M.agent_runtime(uci)
    if not runtime then return nil, err end
    return { token = selected.token, policy = runtime.new_policy(service), runtime = runtime }
end

function M.decorate_request(service, chat)
    local context = service._oasis_execution
    if not context or not context.runtime then return chat end
    return context.runtime.decorate_request(service, chat)
end

function M.command(command)
    command = command or "status"
    if command ~= "agent" and command ~= "normal" and command ~= "status" then
        io.stderr:write("Usage: oasis mode [agent|normal|status]\n")
        return 2
    end
    local result = command == "status" and M.get_status() or M.set_mode(command)
    if result.status ~= "OK" then
        io.stderr:write(tostring(result.error or "Mode operation failed.") .. "\n")
        return 1
    end
    print("Mode: " .. result.mode)
    if command == "status" then
        print("Agent available: " .. (result.available and "yes" or "no"))
        if result.reason then print("Reason: " .. result.reason) end
    end
    return 0
end

return M
