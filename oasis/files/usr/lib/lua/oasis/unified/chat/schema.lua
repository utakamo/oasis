#!/usr/bin/env lua

local util      = require("luci.util")
local uci       = require("luci.model.uci").cursor()
local common    = require("oasis.common")
local jsonc     = require("luci.jsonc")
local debug     = require("oasis.chat.debug")

local M = {}

-- Helpers -----------------------------------------------------------------
local function normalize_newlines(s)
    if not s then return "" end
    return (tostring(s):gsub("\\n", "\n"))
end

local function has_tool_message(chat)
    for _, message in ipairs(chat.messages or {}) do
        if message.role == "tool" then
            return true
        end
    end
    return false
end

local function load_sysmsg()
    local spath = uci:get(common.db.uci.cfg, common.db.uci.sect.role, "path")
    return common.load_conf_file(spath)
end

local function ensure_sysmsg_key(cfg, sysmsg)
    local default_key = uci:get(common.db.uci.cfg, common.db.uci.sect.console, "chat") or "default"
    if (not cfg.sysmsg_key) or (not sysmsg or not sysmsg[cfg.sysmsg_key]) then
        cfg.sysmsg_key = default_key
        if (not sysmsg) or (not sysmsg[cfg.sysmsg_key]) then
            cfg.sysmsg_key = "default"
        end
    end
end

local function insert_system_front(chat, text)
    table.insert(chat.messages, 1, { role = common.role.system, content = normalize_newlines(text) })
end

local function insert_user_end(chat, text)
    table.insert(chat.messages, #chat.messages + 1, { role = common.role.user, content = normalize_newlines(text) })
end

-- Commonized sysmsg insertion helpers -----------------------------------
local function insert_sysmsg(chat, sysmsg, target_key, default_key)
    if not target_key then
        insert_system_front(chat, sysmsg.default[default_key])
        return
    end

    local category, target = target_key:match("^([^.]+)%.([^.]+)$")
    if (category and target) and (sysmsg[category] and sysmsg[category][target]) then
        insert_system_front(chat, sysmsg[category][target])
    else
        insert_system_front(chat, sysmsg.default[default_key])
    end
end

-- Normalize function arguments ------------------------------------------
function M.normalize_arguments(args)
    if type(args) == "string" then
        if args == "{}" then
            return {}
        end

        local ok, parsed = pcall(jsonc.parse, args)
        if ok and type(parsed) == "table" then
            local is_array = (#parsed > 0)
            return is_array and {} or parsed
        end

        return {}
    end

    if type(args) == "table" then
        local is_array = (#args > 0)
        return is_array and {} or args
    end

    return {}
end

-- Main: prepare system/user messages based on format and chat state --------
function M.setup_system_msg(service, chat)
    -- If a tool was involved in previous interaction, clean tool-specific fields and stop.
    if has_tool_message(chat) then
        chat.tool_choice = nil -- Remove tool_choices field assigned in previous interaction
        chat.tools = nil -- Remove tools field assigned in previous interaction
        return
    end

    local cfg = service:get_config()
    local format = service:get_format()
    local sysmsg = load_sysmsg()
    ensure_sysmsg_key(cfg, sysmsg)

    -- If chat has no ID yet, add initial system/user messages depending on format
    if (not cfg.id) or (#cfg.id == 0) then
        if (format == common.ai.format.chat) then
            local target_key = uci:get(common.db.uci.cfg, common.db.uci.sect.console, "chat")
            insert_sysmsg(chat, sysmsg, target_key, "chat")
            return
        end

        if (format == common.ai.format.output) or (format == common.ai.format.rpc_output) then
            if sysmsg and sysmsg[cfg.sysmsg_key] and sysmsg[cfg.sysmsg_key].chat then
                insert_system_front(chat, sysmsg[cfg.sysmsg_key].chat)
            else
                insert_system_front(chat, sysmsg.default.chat)
            end
            return
        end

        if format == common.ai.format.title then
            insert_user_end(chat, sysmsg.general.auto_title)
            return
        end
    end

    -- Prompt format
    if format == common.ai.format.prompt then
        local target_key = uci:get(common.db.uci.cfg, common.db.uci.sect.console, "prompt")
        insert_sysmsg(chat, sysmsg, target_key, "prompt")
        return
    end

    -- Call format
    if format == common.ai.format.call then
        insert_system_front(chat, sysmsg.default.call)
        return
    end
end

local handle_normal_msg = function(chat, speaker, msg)
    -- Regular message
    debug:log("oasis.log", "handle_normal_msg", "Processing regular message")

    if (not speaker.message) or (#speaker.message == 0) then
        debug:log("oasis.log", "handle_normal_msg", "No message content, returning false")
        return false
    end

    msg.content = speaker.message
    debug:log("oasis.log", "handle_normal_msg", string.format("append %s msg: len=%d", tostring(msg.role), #msg.content))

    table.insert(chat.messages, msg)
    debug:log("oasis.log", "handle_normal_msg", "Message added to chat, returning true")
    return true
end

function M.setup_msg(service, chat, speaker)

    debug:log("oasis.log", "setup_msg", string.format("\n--- [ollama.lua][setup_msg] ---"))
    debug:log("oasis.log", "setup_msg", string.format("setup_msg called"))
    debug:log("oasis.log", "setup_msg", string.format("speaker.role = %s", tostring(speaker and speaker.role or "nil")))
    debug:log("oasis.log", "setup_msg", string.format("speaker.message = %s", tostring(speaker and speaker.message or "nil")))
    debug:log("oasis.log", "setup_msg", string.format("speaker.content = %s", tostring(speaker and speaker.content or "nil")))
    debug:log("oasis.log", "setup_msg", string.format("speaker.tool_calls = %s", tostring((speaker and (speaker.tool_calls ~= nil)) and "true" or "nil")))

    -- Remove User Only Message
    if speaker and speaker.content and type(speaker.content) == "string" then
        debug:log("oasis.log", "setup_msg", "Remove User Only Message.")
        local content = jsonc.parse(speaker.content)
        if content and content.user_only then
            content.user_only = nil
            speaker.content = jsonc.stringify(content, false)
        end
    end

    if (not speaker) or (not speaker.role) then
        debug:log("oasis.log", "setup_msg", "No speaker or role, returning false")
        return false
    end

    chat.messages = chat.messages or {}
    local msg = { role = speaker.role }

    local h_tool_info = service:handle_tool_result(chat, speaker, msg)

    if h_tool_info then
        return h_tool_info
    end

    local h_tool_call_res = service:handle_tool_call(chat, speaker, msg)

    if h_tool_call_res then
        return h_tool_call_res
    end

    return handle_normal_msg(chat, speaker, msg)
end

function M.append_chat_data(service, chat)

    local cfg = service:get_config()
    local msgs = chat.messages or {}
    local count = #msgs

    if count < 2 then
        return
    end

    -- Find the last assistant message that does not have tool_calls (if any)
    local ai_idx = nil
    for i = count, 1, -1 do
        local m = msgs[i]
        if m and (m.role == common.role.assistant) and (m.tool_calls == nil) then
            ai_idx = i
            break
        end
    end

    -- Find the most recent user message before that assistant message (if present); this usually excludes tool messages
    local user_idx = nil
    if ai_idx then
        for i = ai_idx - 1, 1, -1 do
            local m = msgs[i]
            if m and (m.role == common.role.user) then
                user_idx = i
                break
            end
        end
    end

    -- Pair selection: if not found, fall back to the last two messages
    local role1, content1, role2, content2
    if user_idx and ai_idx then
        role1, content1 = msgs[user_idx].role, msgs[user_idx].content
        role2, content2 = msgs[ai_idx].role,  msgs[ai_idx].content
    else
        role1, content1 = msgs[count - 1].role, msgs[count - 1].content
        role2, content2 = msgs[count].role,     msgs[count].content
    end

    local message = {
        id = cfg.id,
        role1 = role1, content1 = content1,
        role2 = role2, content2 = content2
    }
    util.ubus("oasis.chat", "append", message)
end

return M
