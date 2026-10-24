local common = require("oasis.common")
local M = {}
local AGENT_PROMPT = "For router-related requests, proactively use `get_tool_list`. "
    .. "Enable a needed disabled tool with `set_tool_enabled` using its exact server and name. "
    .. "After success, Oasis adds its callable definition to the next model request in the same user turn; "
    .. "then call it directly. Enabling does not execute the tool. "
    .. "Make each Tool Search management call separately and wait for its result. "
    .. "Continue using tools as needed until the user request is complete. "
    .. "If required information is missing, reply with NEED_INPUT: followed by a question and wait for the user. "
    .. "Stop for user input or confirmation; do not claim an operation succeeded without a successful tool result."

-- Decorate only the outgoing request, after the selected system message has
-- been prepared. Never persist this mode-dependent instruction in history.
function M.decorate(service, chat)
    local uci = require("luci.model.uci").cursor()
    local context = service._tool_sequence_context
    local active = type(context) == "table" and context.active == true
    if active and context.allow_followup_tools ~= true then return chat end
    local messages = chat.messages or {}
    local last = messages[#messages]
    if last and last.role == "tool"
        and not (active and context.allow_followup_tools == true)
        and service._agent_mode ~= true then
        return chat
    end

    if service:get_format() == common.ai.format.title
        or not common.check_function_calling_enabled(service)
        or not uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool") then
        return chat
    end

    local system_index
    for index, message in ipairs(messages) do
        if message.role == common.role.system then system_index = index end
    end
    local system = system_index and messages[system_index]
    local content = system and system.content or ""
    -- Unified system messages are strings; leave unsupported shapes intact.
    if type(content) ~= "string"
        or content:sub(-#AGENT_PROMPT) == AGENT_PROMPT then
        return chat
    end

    local request = {}
    for key, value in pairs(chat) do request[key] = value end
    request.messages = {}
    for index, message in ipairs(messages) do request.messages[index] = message end
    local augmented = {}
    for key, value in pairs(system or {}) do augmented[key] = value end
    augmented.role = common.role.system
    augmented.content = (content ~= "" and (content .. "\n\n") or "")
        .. AGENT_PROMPT
    if system_index then
        request.messages[system_index] = augmented
    else
        table.insert(request.messages, 1, augmented)
    end
    return request
end

return M
