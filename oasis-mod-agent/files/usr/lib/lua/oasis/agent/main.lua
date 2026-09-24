#!/usr/bin/env lua

-- Agent mode for Oasis.
-- A simple loop that receives a Goal instruction once, automatically repeats tool dispatching, and returns the final response.

local jsonc    = require("luci.jsonc")
local uci      = require("luci.model.uci").cursor()
local common   = require("oasis.common")
local datactrl = require("oasis.chat.datactrl")
local ous      = require("oasis.unified.chat.schema")
local console  = require("oasis.console")
local tool_sequence = require("oasis.chat.tool_sequence")

local DEFAULT_MAX_TURNS = 6

local EXIT_CODE = {
    DONE = 0,
    NEED_INPUT = 20,
    NEED_CONFIRMATION = 21,
    FAILED = 1,
    STUCK = 2
}

local function single_line(s)
    local t = tostring(s or "")
    t = t:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")
    return t
end

local function emit_result(res)
    res = res or {}
    local state = tostring(res.state or "FAILED")
    local code = EXIT_CODE[state] or EXIT_CODE.FAILED

    console.print("STATE: " .. state)
    console.print("MESSAGE: " .. single_line(res.message or ""))
    console.print("TURNS: " .. tostring(res.turns or 0))
    console.print("TOOLS: " .. tostring(res.tool_calls or 0))
    console.print("OASIS_AGENT_RESULT=" .. jsonc.stringify(res, false))
    console.flush()

    os.exit(code)
end

-- Remove remnants of tool/tool_calls to avoid inconsistencies when switching services.
local function sanitize_chat(chat)
    if not chat or not chat.messages then
        return
    end

    local cleaned = {}
    for _, m in ipairs(chat.messages) do
        local is_tool_msg = (m.role == "tool")
        local is_assistant_toolcall = (m.role == common.role.assistant) and (m.tool_calls ~= nil)
        if not is_tool_msg and not is_assistant_toolcall then
            cleaned[#cleaned + 1] = m
        end
    end

    chat.messages = cleaned
    chat.tool_choice = nil
    chat.tools = nil
end

-- args: oasis agent [-t N|t=N|turns=N] <goal ...>
local function parse_args(args)
    local goal_parts = {}
    local max_turns = DEFAULT_MAX_TURNS

    local i = 2
    while i <= #args do
        local a = args[i]
        local num = a:match("^t=(%d+)$") or a:match("^turns=(%d+)$")

        if a == "-t" then
            local nxt = args[i + 1]
            if nxt and nxt:match("^%d+$") then
                max_turns = tonumber(nxt)
                i = i + 1
            else
                goal_parts[#goal_parts + 1] = a
            end
        elseif num then
            max_turns = tonumber(num)
        else
            goal_parts[#goal_parts + 1] = a
        end
        i = i + 1
    end

    local goal = table.concat(goal_parts, " ")
    return goal, max_turns
end

local function read_goal(goal_hint)
    if goal_hint and #goal_hint > 0 then
        return goal_hint
    end
    console.write("Goal: ")
    console.flush()
    local input = console.read() or ""
    return input
end

local function warn_if_tool_disabled()
    local is_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
    if not is_tool then
        console.print("\27[33mWarning:\27[0m local tools are disabled. Agent mode may not be able to act.")
    end
end

local function run(args)
    local goal_from_args, max_turns = parse_args(args or {})
    local goal = read_goal(goal_from_args)

    if not goal or #goal == 0 then
        emit_result({ state = "FAILED", message = "No goal provided" })
    end

    warn_if_tool_disabled()

    local service = common.select_service_obj()
    if not service then
        emit_result({ state = "FAILED", message = "No AI service configuration. Please add/select a service." })
    end

    service:initialize(nil, common.ai.format.chat)

    local chat = datactrl.load_chat_data(service)
    sanitize_chat(chat)

    if not ous.setup_msg(service, chat, { role = common.role.user, message = goal }) then
        emit_result({ state = "FAILED", message = "failed to set up goal message" })
    end

    local res = tool_sequence.run(service, chat, {
        max_ai_requests = max_turns or DEFAULT_MAX_TURNS,
        allow_normal_tool_chaining = true,
        detect_need_input = true,
        stop_on_confirmation = true,
    }) or { state = "FAILED", message = "unknown error" }
    local cfg = service.get_config and service:get_config() or nil
    if cfg and cfg.id and #tostring(cfg.id) > 0 then
        res.chat_id = cfg.id
    end
    -- The historical machine-readable agent result did not expose raw tool
    -- outputs. They may contain user_only data or other tool-private payloads;
    -- keep the aggregate available only to core RPC callers that need it.
    res.tool_info = nil
    emit_result(res)
end

return {
    run = run
}
