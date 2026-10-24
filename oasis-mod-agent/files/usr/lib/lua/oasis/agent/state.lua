local M = {}
local function failure(code, message)
    return {status="NG", changed=false, code=code, error=message}
end
local function is_nonempty_string(value)
    return type(value) == "string" and value ~= ""
end
local function auto_locked(callback)
    local result, err = require("oasis.mode_lock").with_lock(callback)
    return result or failure("auto_state_failed", err)
end
function M.select_tools(tools)
    local registry = require("oasis.local.tool.state")
    local stored, err = require("oasis.agent.store").read()
    if not stored then return nil, failure("auto_state_failed", err) end
    local selected = {}
    for _, tool in ipairs(tools) do
        local key = registry.tool_key(tool)
        local signature = registry.fingerprint(tool)
        selected[key] = registry.is_control_tool(tool.server, tool.name)
            or (signature ~= nil and stored.enabled[key] == signature)
    end
    return selected
end

function M.set_enabled(uci, server_name, tool_name, desired)
    local registry = require("oasis.local.tool.state")
    if not is_nonempty_string(server_name) or not is_nonempty_string(tool_name)
        or (desired ~= true and desired ~= false) then
        return failure("invalid_target", "An exact server, tool and boolean state are required.")
    end
    if registry.is_control_tool("oasis.tool.manager", tool_name) then
        return failure("protected_control_tool", "Agent mode manages Tool Search tools automatically.")
    end
    return auto_locked(function()
        local snapshot, err = registry.snapshot(uci)
        if not snapshot then return err end
        if not snapshot.auto_mode then
            return failure("auto_mode_disabled", "Tool Search is available only in Agent mode.")
        end
        local target
        for _, tool in ipairs(snapshot.tools) do
            if tool.server == server_name and tool.name == tool_name then
                if tool.conflicted or target then
                    return failure("tool_conflict", "The tool name is ambiguous or conflicted.")
                end
                target = tool
            end
        end
        if not target then return failure("tool_not_found", "No tool matches the server and name.") end
        local store = require("oasis.agent.store")
        local stored
        stored, err = store.read()
        if not stored then return failure("auto_state_failed", err) end
        local signature = registry.fingerprint(target)
        if not signature then return failure("invalid_tool", "Invalid tool definition.") end
        local changed = target.enabled ~= desired
        if changed then
            stored.enabled[registry.tool_key(target)] = desired and signature or nil
            local written
            written, err = store.write(stored)
            if not written then return failure("auto_state_failed", err) end
        end
        return { status = "OK", changed = changed, server = server_name,
            tool = tool_name, enable = desired and "1" or "0", enabled = desired }
    end)
end

return M
