#!/usr/bin/env lua

-- Agent mode for Oasis.
-- Goal指示を1回受け取り、ツール呼び分けを自動で繰り返し、最終応答を返す簡易ループ。

local uci      = require("luci.model.uci").cursor()
local common   = require("oasis.common")
local datactrl = require("oasis.chat.datactrl")
local transfer = require("oasis.chat.transfer")
local ous      = require("oasis.unified.chat.schema")
local console  = require("oasis.console")
local debug    = require("oasis.chat.debug")

local DEFAULT_MAX_TURNS = 6

-- tool/tool_callsの残骸を消して、サービス切替時の不整合を避ける。
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

local function agent_loop(service, chat, max_turns)
    local turn = 1

    while turn <= max_turns do
        debug:log("oasis.log", "agent_loop", "turn=" .. tostring(turn))
        local tool_info, plain_text, tool_used = transfer.chat_with_ai(service, chat)

        if tool_used then
            if not service.handle_tool_output then
                console.print("\27[31mError:\27[0m tool handler missing for current service.")
                return
            end

            local ok = service:handle_tool_output(tool_info, chat)
            if not ok then
                console.print("\27[31mError:\27[0m failed to handle tool output.")
                return
            end

            turn = turn + 1
        else
            if plain_text and #plain_text > 0 then
                console.print()
                console.print(plain_text)
            end
            return
        end
    end

    console.print("\27[33mMax turns reached without final answer.\27[0m")
end

local function run(args)
    local goal_from_args, max_turns = parse_args(args or {})
    local goal = read_goal(goal_from_args)

    if not goal or #goal == 0 then
        console.print("No goal provided. Abort.")
        return
    end

    warn_if_tool_disabled()

    local service = common.select_service_obj()
    if not service then
        console.print("Error: No AI service configuration. Please add/select a service.")
        return
    end

    service:initialize(nil, common.ai.format.chat)

    local chat = datactrl.load_chat_data(service)
    sanitize_chat(chat)

    if not ous.setup_msg(service, chat, { role = common.role.user, message = goal }) then
        console.print("Error: failed to set up goal message.")
        return
    end

    agent_loop(service, chat, max_turns or DEFAULT_MAX_TURNS)
end

return {
    run = run
}
