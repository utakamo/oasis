local M = { ABI = 1 }

function M.available(uci)
    local function unavailable(code, message)
        return nil, { status = "NG", code = code, error = message }
    end
    local loaded, state = pcall(require, "oasis.local.tool.state")
    if not loaded or type(state) ~= "table" or state.TOOL_SEARCH_ABI ~= 3
        or type(state.collect) ~= "function" then
        return unavailable("tool_incompatible", "Install a compatible oasis-mod-tool package.")
    end
    if not uci:get_bool("oasis", "support", "local_tool") then
        return unavailable("local_tools_disabled", "Enable Local Tool support to use Agent mode.")
    end
    local tools, err = state.collect(uci)
    if not tools then return nil, err end
    local names = {get_tool_list = 0, set_tool_enabled = 0, set_tool_disabled = 0}
    for _, tool in ipairs(tools) do
        if names[tool.name] ~= nil then
            if not state.is_control_tool(tool.server, tool.name) or tool.conflicted
                or (tool.ubus_method and tool.ubus_method ~= tool.name) then
                return unavailable("control_tools_unavailable", "Agent management tools have conflicting registrations.")
            end
            names[tool.name] = names[tool.name] + 1
        end
    end
    for _, count in pairs(names) do
        if count ~= 1 then
            return unavailable("control_tools_unavailable", "Refresh Agent tool registrations before enabling Agent mode.")
        end
    end
    return true
end

function M.new_policy(service)
    return require("oasis.agent.policy").new(service)
end

function M.select_tools(tools)
    return require("oasis.agent.state").select_tools(tools)
end

function M.decorate_request(service, chat)
    return require("oasis.agent.prompt").decorate(service, chat)
end

return M
