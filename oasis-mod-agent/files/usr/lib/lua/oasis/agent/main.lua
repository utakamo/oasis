#!/usr/bin/env lua

-- Agent mode for Oasis.
-- A simple loop that receives a Goal instruction once, automatically repeats tool dispatching, and returns the final response.

local jsonc    = require("luci.jsonc")
local uci      = require("luci.model.uci").cursor()
local common   = require("oasis.common")
local datactrl = require("oasis.chat.datactrl")
local transfer = require("oasis.chat.transfer")
local ous      = require("oasis.unified.chat.schema")
local console  = require("oasis.console")
local debug    = require("oasis.chat.debug")

local DEFAULT_MAX_TURNS = 6

local EXIT_CODE = {
    DONE = 0,
    NEED_INPUT = 20,
    NEED_CONFIRMATION = 21,
    FAILED = 1,
    STUCK = 2
}

local function trim_prefix_spaces(s)
    return (tostring(s or ""):gsub("^%s+", ""))
end

local function single_line(s)
    local t = tostring(s or "")
    t = t:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")
    return t
end

local function parse_json_maybe(s)
    if type(s) ~= "string" or #s == 0 then
        return nil
    end
    local ok, tbl = pcall(jsonc.parse, s)
    if ok and type(tbl) == "table" then
        return tbl
    end
    return nil
end

local function extract_first_tool_message(tool_info_tbl)
    if not tool_info_tbl or type(tool_info_tbl.tool_outputs) ~= "table" then
        return ""
    end
    for _, t in ipairs(tool_info_tbl.tool_outputs) do
        if t and type(t.output) == "string" then
            local parsed = parse_json_maybe(t.output)
            if parsed then
                local fields = { "user_only", "result", "message", "error" }
                for _, k in ipairs(fields) do
                    local v = parsed[k]
                    if type(v) == "string" and v:match("%S") then
                        return v
                    end
                end
            end
        end
    end
    return ""
end

local function detect_confirmation(tool_info_tbl)
    if not tool_info_tbl or type(tool_info_tbl) ~= "table" then
        return nil
    end

    local confirm = {
        reboot = (tool_info_tbl.reboot == true),
        shutdown = (tool_info_tbl.shutdown == true),
        prepare_service_restart = nil
    }

    if type(tool_info_tbl.tool_outputs) == "table" then
        for _, t in ipairs(tool_info_tbl.tool_outputs) do
            if t and type(t.output) == "string" then
                local parsed = parse_json_maybe(t.output)
                if parsed then
                    if parsed.reboot == true then confirm.reboot = true end
                    if parsed.shutdown == true then confirm.shutdown = true end
                    if type(parsed.prepare_service_restart) == "string" then
                        local svc = parsed.prepare_service_restart:match("^%s*(.-)%s*$")
                        if svc and #svc > 0 then
                            confirm.prepare_service_restart = svc
                        end
                    end
                end
            end
        end
    end

    if confirm.reboot or confirm.shutdown or (confirm.prepare_service_restart ~= nil) then
        return confirm
    end
    return nil
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

local function agent_loop(service, chat, max_turns)
    local turns = 0
    local tool_calls = 0
    local last_tool_names = {}

    while turns < max_turns do
        turns = turns + 1
        debug:log("oasis.log", "agent_loop", "turn=" .. tostring(turns))

        local ok, tool_info, plain_text, tool_used = pcall(transfer.chat_with_ai, service, chat)
        if not ok then
            return {
                state = "FAILED",
                message = "chat_with_ai failed: " .. tostring(tool_info),
                turns = turns,
                tool_calls = tool_calls
            }
        end

        if tool_used then
            local tool_info_tbl = parse_json_maybe(tool_info)
            last_tool_names = {}
            if tool_info_tbl and type(tool_info_tbl.tool_outputs) == "table" then
                tool_calls = tool_calls + #tool_info_tbl.tool_outputs
                for _, t in ipairs(tool_info_tbl.tool_outputs) do
                    if t and type(t.name) == "string" and #t.name > 0 then
                        last_tool_names[#last_tool_names + 1] = t.name
                    end
                end
            end

            if not service.handle_tool_output then
                return {
                    state = "FAILED",
                    message = "tool handler missing for current service",
                    turns = turns,
                    tool_calls = tool_calls,
                    last_tool_names = last_tool_names
                }
            end

            local ok2, handled = pcall(function()
                return service:handle_tool_output(tool_info, chat)
            end)
            if (not ok2) or (not handled) then
                return {
                    state = "FAILED",
                    message = "failed to handle tool output",
                    turns = turns,
                    tool_calls = tool_calls,
                    last_tool_names = last_tool_names
                }
            end

            local confirm = detect_confirmation(tool_info_tbl)
            if confirm then
                local msg = extract_first_tool_message(tool_info_tbl)
                if msg == "" then
                    msg = "Confirmation required"
                end
                return {
                    state = "NEED_CONFIRMATION",
                    message = msg,
                    turns = turns,
                    tool_calls = tool_calls,
                    last_tool_names = last_tool_names,
                    confirmation = confirm
                }
            end
        else
            local text = tostring(plain_text or "")
            local trimmed = trim_prefix_spaces(text)
            local need = trimmed:match("^NEED_INPUT:%s*(.*)$")
            if need then
                return {
                    state = "NEED_INPUT",
                    message = need,
                    turns = turns,
                    tool_calls = tool_calls,
                    last_tool_names = last_tool_names
                }
            end

            return {
                state = "DONE",
                message = text,
                turns = turns,
                tool_calls = tool_calls,
                last_tool_names = last_tool_names
            }
        end
    end

    return {
        state = "STUCK",
        message = "Max turns reached without final answer",
        turns = turns,
        tool_calls = tool_calls,
        last_tool_names = last_tool_names
    }
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
    service._agent_mode = true

    local chat = datactrl.load_chat_data(service)
    sanitize_chat(chat)

    if not ous.setup_msg(service, chat, { role = common.role.user, message = goal }) then
        emit_result({ state = "FAILED", message = "failed to set up goal message" })
    end

    local res = agent_loop(service, chat, max_turns or DEFAULT_MAX_TURNS) or { state = "FAILED", message = "unknown error" }
    local cfg = service.get_config and service:get_config() or nil
    if cfg and cfg.id and #tostring(cfg.id) > 0 then
        res.chat_id = cfg.id
    end
    emit_result(res)
end

return {
    run = run
}
