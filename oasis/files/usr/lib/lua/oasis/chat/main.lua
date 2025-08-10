#!/usr/bin/env lua

local sys               = require("luci.sys")
local util              = require("luci.util")
local uci               = require("luci.model.uci").cursor()
local jsonc             = require("luci.jsonc")
local transfer          = require("oasis.chat.transfer")
local datactrl          = require("oasis.chat.datactrl")
local common            = require("oasis.common")
local debug             = require("oasis.chat.debug")

local error_msg = {}
error_msg.load_service1 = "Error!\n\tThere is no AI service configuration."
error_msg.load_service2 = "\tPlease add the service configuration with the add command."

local chat_history = function(chat)
    print(#chat.messages)
    print()
    local chat_json = jsonc.stringify(chat, false)
    print(chat_json)
end

local storage = function(args)

    local storage = {}
    local current_storage_path = uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "path")
    local chat_max = uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "chat_max")

    local output = {}
    output.title = {}
    output.title.current    = "[Current Storage Config]"
    output.title.setup      = "[Setup New Storage Config]"
    output.title.input      = "please input new config!"
    output.format_1         = "%-30s >> %s"
    output.format_2         = "%-30s >> "
    output.path             = "path (Blank if not change)"
    output.chat_max         = "chat-max (Blank if not change)"
    output.error.config     = "Error! Failed to load configuration information."
    output.error.path       = "Error! Invalid directory path."

    print(output.title.current)
    print(string.format(output.format_1, "path", current_storage_path))
    print(string.format(output.format_1, "chat-max", chat_max))

    print(output.title.setup)
    print(output.title.input)

    if (not args.path) then
        io.write(string.format(output.format_2, output.path))
        io.flush()
        storage.path = io.read()
    else
        print(string.format(output.format_1, "path", args.path))
        storage.path = args.path
    end

    if (not args.chat_max) then
        io.write(string.format(output.format_2, output.chat_max))
        io.flush()
        storage.chat_max = io.read()
    else
        print(string.format(output.format_1, "chat-max", args.chat_max))
        storage.chat_max = args.chat_max
    end

    if #storage.path > 0 then
        local prefix = uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "prefix")

        if (#current_storage_path == 0) or (#prefix == 0) then
            print(output.error.config)
            return
        end

        if storage.path:match("^[%w/]+$") then
            sys.exec("mv " .. current_storage_path .. "/" .. prefix .. "* " .. storage.path)
        else
            print(output.error.path)
            return
        end

        uci:set(common.db.uci.cfg, common.db.uci.sect.storage, "path", storage.path)
    end

    if #storage.chat_max > 0 then
        uci:set(common.db.uci.cfg, common.db.uci.sect.storage, "chat_max", storage.chat_max)
    end

    uci:commit(common.db.uci.cfg)
end

local add = function(args)

    local setup = {}

    local output = {}
    output.format_1        = "%-64s >> "
    output.format_2        = "%-64s >> %s"
    -- output.service         = "Service (\"Ollama\" or \"OpenAI\" or \"Anthropic\" or \"Google Gemini\")"
    output.service         = "Service (\"Ollama\" or \"OpenAI\")"
    output.endpoint        = "Endpoint"
    output.api_key         = "API KEY (leave blank if none)"
    output.model           = "LLM MODEL"
    output.max_tokens      = "Max Tokens (%d ～ %d)"               -- Anthropic Only
    output.type            = "Thinking (\"%s\" or \"%s\")"         -- Anthropic Only
    output.budget_tokens   = "Budget Tokens (%d ～ %d)"            -- Anthropic Only

    local val = {}
    val.type = {}
    val.type.enable = "enabled"
    val.type.disable = "disabled"
    val.max_tokens = {}
    val.max_tokens.min = 1000
    val.max_tokens.max = 30000
    val.budget_tokens = {}
    val.budget_tokens.min = 1000
    val.budget_tokens.max = 20000

    output.max_tokens = string.format(output.max_tokens, val.max_tokens.min, val.max_tokens.max)
    output.type = string.format(output.type, val.type.disable, val.type.enable)
    output.budget_tokens = string.format(output.budget_tokens, val.budget_tokens.min, val.budget_tokens.max)

    setup.identifier = common.generate_service_id("seed")

    if (not args.service) then
        repeat
            io.write(string.format(output.format_1, output.service))
            io.flush()
            setup.service = io.read()
        until (setup.service == common.ai.service.ollama.name)
                or (setup.service == common.ai.service.openai.name)
                or (setup.service == common.ai.service.anthropic.name)
                or (setup.service == common.ai.service.gemini.name)
    else
        if (args.service == common.ai.service.ollama.name)
            or (args.service == common.ai.service.openai.name)
            or (args.service == common.ai.service.anthropic.name)
            or (args.service == common.ai.service.gemini.name) then

            io.write(string.format(output.format_2, output.service, args.service))
            setup.service = args.service
        else
            repeat
                io.write(string.format(output.format_1, output.service))
                io.flush()
                setup.service = io.read()
            until (setup.service == common.ai.service.ollama.name)
                    or (setup.service == common.ai.service.openai.name)
                    or (setup.service == common.ai.service.anthropic.name)
                    or (setup.service == common.ai.service.gemini.name)
        end
    end

    if (not args.endpoint) then
        io.write(string.format(output.format_1, output.endpoint))
        io.flush()
        setup.endpoint = io.read() or ""
    else
        print(string.format(output.format_2, output.endpoint, args.endpoint))
        setup.endpoint = args.endpoint or ""
    end

    if setup.service == common.ai.service.anthropic.name then
        repeat
            io.write(string.format(output.format_1, output.max_tokens))
            io.flush()
            setup.max_tokens = io.read()
        until (tonumber(setup.max_tokens) >= val.max_tokens.min)
            and (tonumber(setup.max_tokens) <= val.max_tokens.max)

        repeat
            io.write(string.format(output.format_1, output.type))
            io.flush()
            setup.type = io.read()
        until (setup.type == val.type.disable) or (setup.type == val.type.enable)

        if setup.type == val.type.enable then
            repeat
                io.write(string.format(output.format_1, output.budget_tokens))
                io.flush()
                setup.budget_tokens = io.read()
            until (tonumber(setup.budget_tokens) >= val.budget_tokens.min)
                and (tonumber(setup.budget_tokens) <= val.budget_tokens.max)
        end
    end

    if (not args.api_key) then
        io.write(string.format(output.format_1, output.api_key))
        io.flush()
        setup.api_key = io.read() or ""
    else
        print(string.format(output.format_2, output.api_key, args.api_key))
        setup.api_key = args.api_key or ""
    end

    if (not args.model) then
        io.write(string.format(output.format_1, output.model))
        io.flush()
        setup.model = io.read() or ""
    else
        print(string.format(output.format_2, output.model, args.model))
        setup.model = args.model or ""
    end

    local endpoint_op_name = "unknown"

    if setup.service == common.ai.service.ollama.name then
        endpoint_op_name = "ollama_endpoint"
    elseif setup.service == common.ai.service.openai.name then
        endpoint_op_name = "openai_custom_endpoint"
    elseif setup.service == common.ai.service.anthropic.name then
        endpoint_op_name = "anthropic_custom_endpoint"
    elseif setup.service == common.ai.service.gemini.name then
        endpoint_op_name = "gemini_custom_endpoint"
    end

    local unnamed_section = uci:add(common.db.uci.cfg, common.db.uci.sect.service)
    uci:set(common.db.uci.cfg, unnamed_section, "identifier", setup.identifier)
    uci:set(common.db.uci.cfg, unnamed_section, "name", setup.service)
    uci:set(common.db.uci.cfg, unnamed_section, endpoint_op_name, setup.endpoint)

    if setup.service == common.ai.service.openai.name then
        uci:set(common.db.uci.cfg, unnamed_section, "openai_endpoint_type", common.endpoint.type.custom)
    elseif setup.service == common.ai.service.anthropic.name then
        uci:set(common.db.uci.cfg, unnamed_section, "anthropic_endpoint_type", common.endpoint.type.custom)
    elseif setup.service == common.ai.service.gemini.name then
        uci:set(common.db.uci.cfg, unnamed_section, "gemini_endpoint_type", common.endpoint.type.custom)
    end

    uci:set(common.db.uci.cfg, unnamed_section, "api_key", setup.api_key)
    uci:set(common.db.uci.cfg, unnamed_section, "model", setup.model)

    if setup.max_tokens then
        uci:set(common.db.uci.cfg, unnamed_section, "max_tokens", setup.max_tokens)
    end

    if setup.type then
        uci:set(common.db.uci.cfg, unnamed_section, "type", setup.type)
    end

    if setup.budget_tokens then
        uci:set(common.db.uci.cfg, unnamed_section, "budget_tokens", setup.budget_tokens)
    end

    uci:commit(common.db.uci.cfg)
end

local change = function(opt, arg)

    local output = {}
    output.service = {}
    output.service.update       = "Service Update!"
    output.service.not_found    = "Service Not Found..."

    local is_update = false

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(service)
        if service.identifier == arg.identifier then
            is_update = true
            if opt.u then
                if service.name == common.ai.service.ollama.name then
                    uci:set(common.db.uci.cfg, service[".name"], "ollama_endpoint", opt.u)
                elseif service.name == common.ai.service.openai.name then
                    uci:set(common.db.uci.cfg, service[".name"], "openai_custom_endpoint", opt.u)
                    uci:set(common.db.uci.cfg, service[".name"], "openai_endpoint_type", common.endpoint.type.custom)
                elseif service.name == common.ai.service.anthropic.name then
                    uci:set(common.db.uci.cfg, service[".name"], "anthropic_custom_endpoint", opt.u)
                    uci:set(common.db.uci.cfg, service[".name"], "anthropic_endpoint_type", common.endpoint.type.custom)
                elseif common.ai.service.gemini.name then
                    uci:set(common.db.uci.cfg, service[".name"], "gemini_custom_endpoint", opt.u)
                    uci:set(common.db.uci.cfg, service[".name"], "gemini_endpoint_type", common.endpoint.type.custom)
                end
            end
            if opt.k then
                uci:set(common.db.uci.cfg, service[".name"], "api_key", opt.k)
            end
            if opt.m then
                uci:set(common.db.uci.cfg, service[".name"], "model", opt.m)
            end
            if opt.s then
                uci:set(common.db.uci.cfg, service[".name"], "storage", opt.s)
            end
            uci:commit(common.db.uci.cfg)
        end
    end)

    if is_update then
        print(output.service.update)
    else
        print(output.service.not_found)
    end
end

local show_service_list = function()

    local output = {}
    output.service = {}
    output.service.in_use = function(index, identifier)
        print("\n\27[1;34m[" .. index .. "] : " .. identifier .. " \27[1;32m(in use)\27[0m")
    end

    output.service.not_in_use = function(index, identifier)
        print("\n\27[1;34m[" .. index .. "] : " .. identifier .. " \27[0m")
    end

    output.line = function()
        print("-----------------------------------------------")
    end

    output.item = function(name, value)
        local display_value = value or "(not set)"
        io.write(string.format("%-8s >> \27[33m%s\27[0m\n", name, display_value))
        io.flush()
    end

    local index = 0

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(tbl)
        index = index + 1
        if tbl.name then
            if index == 1 then
                output.service.in_use(index, tbl.identifier)
            else
                output.service.not_in_use(index, tbl.identifier)
            end

            output.line()

            if tbl.name then
                output.item("AI Service", tbl.name)
                local endpoint_str = "Endpoint"
                if tbl.name == common.ai.service.ollama.name then
                    output.item(endpoint_str, tbl.ollama_endpoint)
                elseif tbl.name == common.ai.service.openai.name then
                    if (tbl.openai_endpoint_type) and (tbl.openai_endpoint_type == common.endpoint.type.default) then
                        output.item(endpoint_str, common.ai.service.openai.endpoint)
                    elseif (tbl.openai_endpoint_type) and (tbl.openai_endpoint_type == common.endpoint.type.custom) then
                        output.item(endpoint_str, tbl.openai_custom_endpoint)
                    end
                elseif tbl.name == common.ai.service.anthropic.name then
                    if (tbl.anthropic_endpoint_type) and (tbl.anthropic_endpoint_type == common.endpoint.type.default) then
                        output.item(endpoint_str, common.ai.service.anthropic.endpoint)
                    elseif (tbl.anthropic_endpoint_type) and (tbl.anthropic_endpoint_type == common.endpoint.type.custom) then
                        output.item(endpoint_str, tbl.anthropic_custom_endpoint)
                    end
                elseif tbl.name == common.ai.service.gemini.name then
                    if (tbl.gemini_endpoint_type) and (tbl.gemini_endpoint_type == common.endpoint.type.default) then
                        output.item(endpoint_str, common.ai.service.gemini.endpoint)
                    elseif (tbl.gemini_endpoint_type) and (tbl.gemini_endpoint_type == common.endpoint.type.custom) then
                        output.item(endpoint_str, tbl.gemini_custom_endpoint)
                    end
                end
            end

            output.item("API KEY", tbl.api_key)
            output.item("MODEL", tbl.model)
        end
    end)
end

local delete = function(arg)

    if not arg then
        return
    end

    local output = {}
    output.service = {}
    output.service.confirm_service_delete = function(identifier)
        local reply

        repeat
            io.write("Do you delete service [" ..identifier .. "] (Y/N):")
            io.flush()

            reply = io.read()

        until reply == 'Y' or reply == 'N'

        if reply == 'N' then
            print("canceled.")
            return 'N'
        end

        return 'Y'
    end

    output.service.delete = function(service)
        uci:delete(common.db.uci.cfg, service)
        uci:commit(common.db.uci.cfg)
        print("Delete service [" .. service .. "]")
    end

    output.service.not_found = function(identifier)
        print("Error: Service ID('" .. identifier .. "') was not found in the configuration.")
    end

    if not arg.identifier then
        return
    end

    local target_section
    local found = false

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(service)
        if not found and service.identifier == arg.identifier then
            target_section = service[".name"]
            found = true
            return false
        end
    end)

    if (not target_section) or (#target_section == 0) then
        output.service.not_found(arg.identifier)
        return
    end

    if output.service.confirm_service_delete(arg.identifier) == 'N' then
        return
    end

    output.service.delete(target_section)
end

local select = function(arg)

    if not arg.identifier then
        return
    end

    local target_section = ""

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(service)
        if service.identifier == arg.identifier then
            target_section = service[".name"]
        end
    end)

    if #target_section == 0 then
        print("Identifer Name: " .. arg.identifier .. " is not found.")
        return
    end

    -- swap section data
    uci:reorder(common.db.uci.cfg, target_section, 1)
    uci:commit(common.db.uci.cfg)

    local model = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "model")
    print(arg.identifier .. " is selected.")
    print("Target model: \27[33m" .. model .. "\27[0m")
end

local chat = function(arg)

    local service = common.select_service_obj()

    if not service then
        print(error_msg.load_service1 .. "\n" .. error_msg.load_service2)
        return
    end

    service:initialize(arg, common.ai.format.chat)
    local cfg = service:get_config()

    print("-----------------------------------")
    print(string.format("%-14s :\27[33m %s \27[0m", "Identifer", cfg.identifier))
    print(string.format("%-14s :\27[33m %s \27[0m", "AI Service", cfg.service))
    print(string.format("%-14s :\27[33m %s \27[0m", "Model", cfg.model))
    print("-----------------------------------")

    local chat = datactrl.load_chat_data(service)

    while true do

        local your_message

        repeat
            io.write("\27[32m\nYou :\27[0m")
            io.flush()
            your_message = io.read()

            if not your_message then
                return
            end

            if your_message == "history" then
                chat_history(chat)
            end

        until (#your_message > 0) and (your_message ~= "history")

        if your_message == "exit" then
            break;
        end

        -- Once the message to be sent to the AI is prepared, write it to storage and then send it.
        if service:setup_msg(chat, {role = common.role.user, message = your_message}) then
            datactrl.record_chat_data(service, chat)
            transfer.chat_with_ai(service, chat)
        end
    end
end

local delchat = function(arg)

    local is_search = common.search_chat_id(arg.id)

    if is_search then
        io.write("Do you delete chat data id=" ..arg.id .. " ? (Y/N):")
        io.flush()

        local reply = io.read()

        if reply == 'N' then
            print("canceled.")
        end
    else
        print("No chat data found for id=" .. arg.id)
    end

    local storage_path = uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "path")
    local prefix = uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "prefix")
    local file_path = storage_path .. "/" .. prefix .. arg.id
    os.remove(file_path)

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.chat, function(tbl)
        if tbl.id == arg.id then
            uci:delete(common.db.uci.cfg, tbl[".name"])
        end
    end)

    uci:commit(common.db.uci.cfg)

    print("Delete chat data id=" .. arg.id)
end

local prompt = function(arg)

    local service = common.select_service_obj()

    if not service then
        print(error_msg.load_service1 .. "\n" .. error_msg.load_service2)
        return
    end

    service:initialize(arg, common.ai.format.prompt)

    local prompt = datactrl.load_chat_data(service)

    -- Once the message to be sent to the AI is prepared, write it to storage and then send it.
    if service:setup_msg(prompt, { role = common.role.user, message = arg.message }) then
        transfer.chat_with_ai(service, prompt)
        print()
    end
end

local sysmsg = function(arg)

    local sysmsg = common.load_conf_file("/etc/oasis/oasis.conf")

    if arg then

        if arg.cmd then
            debug:log("sysmsg.log", "arg.cmd = " .. arg.cmd)
        end

        if arg.option then
            debug:log("sysmsg.log", "arg.option = " .. arg.option)
        end

        if arg.param then
            debug:log("sysmsg.log", "arg.param = " .. arg.param)
        end
    end

    if (not arg) or (not arg.cmd) or (not arg.option) or (not arg.param)
         or ((arg.cmd ~= "chat") and (arg.cmd ~= "prompt"))
         or ((arg.option ~= "-c") and (arg.option ~= "-s")) then

        -- General system Message
        -- print("--- General ---")
        -- print("\27[33mSystem message for generating a chat title: \27[34m[general.auto_title] \27[0m")
        -- print(sysmsg.general.auto_title)
        -- print()

        -- Default System Messages
        print("\27[32m--- Default ---\27[0m")
        print("\27[33mSystem message for chat command: \27[34m[default.chat] \27[0m")
        print(sysmsg.default.chat)
        print()

        print("\27[33mSystem message for prompt command: \27[34m[default.prompt] \27[0m")
        print(sysmsg.default.prompt)
        print()

        for key, system_message_tbl in pairs(sysmsg) do
            local suffix = key:match("^custom_(%d+)$")
            if suffix then
                print("\27[32m--- CUSTOM " .. suffix .. " ---\27[0m")
                for cmd, system_message in pairs(system_message_tbl) do
                    if cmd == "chat" then
                        print("\27[33mSystem message for chat command: \27[34m[custom_" .. suffix .. ".chat] \27[0m")
                        print(system_message)
                        print()
                    elseif cmd == "prompt" then
                        print("\27[33mSystem message for prompt command: \27[34m[custom_" .. suffix .. ".prompt] \27[0m")
                        print(system_message)
                        print()
                    end
                end
            end
        end

        local sysmsg_key_for_chat   = uci:get(common.db.uci.cfg, common.db.uci.sect.console, "chat")
        local sysmsg_key_for_prompt = uci:get(common.db.uci.cfg, common.db.uci.sect.console, "prompt")

        print()
        print("=============== \27[32mCurrent Setting\27[0m ===============")
        print("chat command ------> " .. "\27[34m" .. sysmsg_key_for_chat .. "\27[0m")
        print("prompt command ----> " .. "\27[34m" .. sysmsg_key_for_prompt .. "\27[0m")
        print("===============================================")
        return
    end

    if (arg.option == "-s") and arg.param then
        local category, target = arg.param:match("^([^.]+)%.([^.]+)$")
        if (category and target) and (sysmsg[category]) and (sysmsg[category][target]) then
            uci:set(common.db.uci.cfg, common.db.uci.sect.console, arg.cmd, arg.param)
            uci:commit(common.db.uci.cfg)
            print(arg.cmd .. " command ---> " .. arg.param)
        else
            print("Not Found ...")
        end
    elseif (arg.option == "-c") and (arg.param) then

        local target_idx = 1

        for key, _ in pairs(sysmsg) do
            local suffix_str = key:match("^custom_(%d+)$")
            if suffix_str then
                local suffix_int = tonumber(suffix_str)
                if (suffix_int) and (target_idx > suffix_int) then
                    target_idx = suffix_int
                end
            end
        end

        local category = "custom_" .. target_idx

        if not sysmsg[category] then
            sysmsg[category] = {}
        end

        sysmsg[category][arg.cmd] = arg.param
        local is_update = common.update_conf_file("/etc/oasis/oasis.conf", sysmsg)

        if not is_update then
            print("error!")
        end

        print("Update Success!!")
    end
end

local output = function(arg)

    -- Entry log
    debug:log("oasis_output.log", "\n--- [main.lua][output] ---")

    local has_msg = arg and type(arg.message) == "string" and (#arg.message > 0)
    local has_tools = arg and (type(arg.tool_outputs) == "table") and (#arg.tool_outputs > 0)

    -- Payload flags
    debug:log(
        "oasis_output.log",
        string.format("[output] has_msg=%s, has_tools=%s",
            tostring(has_msg), tostring(has_tools))
    )

    if (not has_msg) and (not has_tools) then
        debug:log("oasis_output.log", "[output] No message or tool_outputs. Early return.")
        return
    end

    local service = common.select_service_obj()
    if not service then
        print(error_msg.load_service1 .. "\n" .. error_msg.load_service2)
        debug:log("oasis_output.log", "[output] select_service_obj failed.")
        return
    end

    service:initialize(arg, common.ai.format.output)
    debug:log("oasis_output.log", "[output] service.initialize done.")

    local cfg_dbg = service.get_config and service:get_config() or nil
    if cfg_dbg then
        debug:log(
            "oasis_output.log",
            string.format(
                "[output] cfg: service=%s, model=%s, id=%s",
                tostring(cfg_dbg.service or "-"),
                tostring(cfg_dbg.model or "-"),
                tostring(cfg_dbg.id or "")
            )
        )
    end

    local chat_ctx = datactrl.load_chat_data(service)
    debug:log("oasis_output.log", "Load chat data ...")
    debug:dump("oasis_output.log", chat_ctx)

    -- 1) If tool outputs exist, append tool messages to the conversation history first
    if has_tools then
        debug:log(
            "oasis_output.log",
            string.format("[output] append %d tool message(s)", #arg.tool_outputs)
        )
        for _, t in ipairs(arg.tool_outputs) do
            local content = t.output
            if type(content) ~= "string" then
                content = jsonc.stringify(content, false)
            end
            debug:log(
                "oasis_output.log",
                string.format(
                    "[output] tool msg: id=%s, name=%s, len=%d",
                    tostring(t.tool_call_id or t.id or ""),
                    tostring(t.name or ""),
                    tonumber((content and #content) or 0)
                )
            )
            service:setup_msg(chat_ctx, {
                role = "tool",
                tool_call_id = t.tool_call_id or t.id,
                name = t.name,
                content = content
            })
        end
    end

    -- 2) If a user message exists, append it
    if has_msg then
        local msg_len = (arg.message and #arg.message) or 0
        debug:log(
            "oasis_output.log",
            string.format("[output] append user message: len=%d", msg_len)
        )
        service:setup_msg(chat_ctx, { role = common.role.user, message = arg.message })
    end

    -- 3) Persist and send to the AI service
    debug:log("oasis_output.log", "[output] record_chat_data start")
    datactrl.record_chat_data(service, chat_ctx)
    debug:log("oasis_output.log", "[output] record_chat_data done")

    debug:log("oasis_output.log", "[output] call chat_with_ai")
    local new_chat_info, message = transfer.chat_with_ai(service, chat_ctx)
    local msg_len = (message and #message) or 0
    debug:log(
        "oasis_output.log",
        string.format("[output] chat_with_ai returned: new_chat_info_len=%d, message_len=%d",
            (new_chat_info and #new_chat_info) or 0,
            msg_len)
    )
    return new_chat_info, message
end

local rpc_output = function(arg)

    debug:log("oasis.log", "\n--- [main.lua][rpc_output] ---")

    local enable = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.rpc, "enable")

    if not enable then
        return { status = common.status.error, desc = "Oasis's RPC function is not enabled." }
    end

    if not arg then
        return { status = common.status.error, desc = "No argument." }, nil, nil
    end

    local service = common.select_service_obj()

    if not service then
        return { status = common.status.error, desc = "AI Service Not Found." }, nil, nil
    end

    service:initialize(arg, common.ai.format.rpc_output)

    debug:log("oasis.log", "[main.lua][rpc_output] Service initialize done ...")

    local rpc_output = datactrl.load_chat_data(service)

    debug:log("oasis.log", "[main.lua][rpc_output] Load chat data ...")
    debug:dump("oasis.log", rpc_output)

    local new_chat_info, message = ""

    -- Once the message to be sent to the AI is prepared, write it to storage and then send it.
    if service:setup_msg(rpc_output, { role = common.role.user, message = arg.message}) then
        datactrl.record_chat_data(service, rpc_output)
        debug:log("oasis.log", "[main.lua][rpc_output] record_chat_data done ...")
        new_chat_info, message = transfer.chat_with_ai(service, rpc_output)
        debug:log("oasis.log", "[main.lua][rpc_output] chat_with_ai done ...")
    end

    if new_chat_info then
        debug:log("oasis.log", "[main.lua][rpc_output] new_chat_info dump")
        debug:log("oasis.log", new_chat_info)
    end

    debug:log("oasis.log", "[main.lua][rpc_output] message = " .. message)

    return { status = common.status.ok }, new_chat_info, message
end

local rename = function(arg)
    local result = util.ubus("oasis.title", "manual_set", {id = arg.id, title = arg.title})

    if result.status == "OK" then
        print("Changed title of chat data with id=" .. arg.id  .. " to " .. result.title .. ".")
    else
        print("Chat data for id=" .. arg.id .. " could not be found.")
    end
end

local list = function()

    local list = util.ubus("oasis.chat", "list", {})

    if #list.item == 0 then
        print("No chat file ...")
        return
    end

    print("-----------------------------------------------------")
    print(string.format(" %3s | %-30s | %s", "No.", "title", "id" ))
    print("-----------------------------------------------------")

    for i, chat_info in ipairs(list.item) do
        print(string.format("[%2d]: %-30s   %s", i, chat_info.title, chat_info.id))
    end
end

return {
    storage = storage,
    add = add,
    change = change,
    delete = delete,
    select = select,
    show_service_list = show_service_list,
    chat = chat,
    delchat = delchat,
    prompt = prompt,
    sysmsg = sysmsg,
    output = output,
    rpc_output = rpc_output,
    rename = rename,
    list = list,
}
