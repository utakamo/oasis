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

-- Service configuration constants
local SERVICE_CONFIG = {
    VALID_SERVICES = {
        common.ai.service.ollama.name,
        common.ai.service.openai.name,
        common.ai.service.anthropic.name,
        common.ai.service.gemini.name
    },

    ENDPOINT_FIELDS = {
        [common.ai.service.ollama.name] = "ollama_endpoint",
        [common.ai.service.openai.name] = "openai_custom_endpoint",
        [common.ai.service.anthropic.name] = "anthropic_custom_endpoint",
        [common.ai.service.gemini.name] = "gemini_custom_endpoint"
    },

    ENDPOINT_TYPES = {
        [common.ai.service.openai.name] = "openai_endpoint_type",
        [common.ai.service.anthropic.name] = "anthropic_endpoint_type",
        [common.ai.service.gemini.name] = "gemini_endpoint_type"
    },

    ANTHROPIC_LIMITS = {
        MAX_TOKENS = { min = 1000, max = 30000 },
        BUDGET_TOKENS = { min = 1000, max = 20000 },
        THINKING_TYPES = { enabled = "enabled", disabled = "disabled" }
    },

    -- Service configuration mapping for change function
    SERVICE_CONFIG = {
        [common.ai.service.ollama.name] = {
            endpoint_field = "ollama_endpoint",
            endpoint_type_field = nil,
            endpoint_type_value = nil
        },
        [common.ai.service.openai.name] = {
            endpoint_field = "openai_custom_endpoint",
            endpoint_type_field = "openai_endpoint_type",
            endpoint_type_value = common.endpoint.type.custom
        },
        [common.ai.service.anthropic.name] = {
            endpoint_field = "anthropic_custom_endpoint",
            endpoint_type_field = "anthropic_endpoint_type",
            endpoint_type_value = common.endpoint.type.custom
        },
        [common.ai.service.gemini.name] = {
            endpoint_field = "gemini_custom_endpoint",
            endpoint_type_field = "gemini_endpoint_type",
            endpoint_type_value = common.endpoint.type.custom
        }
    }
}

-- Output format definitions
local function get_output_formats()
    local output = {}

    -- Basic formats
    output.format_1 = "%-64s >> "
    output.format_2 = "%-64s >> %s"

    -- Field labels
    output.service = "Service (\"Ollama\" or \"OpenAI\")"
    output.endpoint = "Endpoint"
    output.api_key = "API KEY (leave blank if none)"
    output.model = "LLM MODEL"

    -- Anthropic-specific formats
    output.max_tokens = string.format("Max Tokens (%d ～ %d)",
        SERVICE_CONFIG.ANTHROPIC_LIMITS.MAX_TOKENS.min,
        SERVICE_CONFIG.ANTHROPIC_LIMITS.MAX_TOKENS.max)
    output.type = string.format("Thinking (\"%s\" or \"%s\")",
        SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.disabled,
        SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.enabled)
    output.budget_tokens = string.format("Budget Tokens (%d ～ %d)",
        SERVICE_CONFIG.ANTHROPIC_LIMITS.BUDGET_TOKENS.min,
        SERVICE_CONFIG.ANTHROPIC_LIMITS.BUDGET_TOKENS.max)

    return output
end

-- Validate service name
local function is_valid_service(service_name)
    for _, valid_service in ipairs(SERVICE_CONFIG.VALID_SERVICES) do
        if service_name == valid_service then
            return true
        end
    end
    return false
end

-- Collect service name input
local function collect_service_name(args, output)
    local setup = {}

    if not args.service then
        repeat
            io.write(string.format(output.format_1, output.service))
            io.flush()
            setup.service = io.read()
        until is_valid_service(setup.service)
    else
        if is_valid_service(args.service) then
            io.write(string.format(output.format_2, output.service, args.service))
            setup.service = args.service
        else
            repeat
                io.write(string.format(output.format_1, output.service))
                io.flush()
                setup.service = io.read()
            until is_valid_service(setup.service)
        end
    end

    return setup.service
end

-- Collect endpoint input
local function collect_endpoint(args, output)
    if not args.endpoint then
        io.write(string.format(output.format_1, output.endpoint))
        io.flush()
        return io.read() or ""
    else
        print(string.format(output.format_2, output.endpoint, args.endpoint))
        return args.endpoint or ""
    end
end

-- Collect Anthropic-specific configuration
local function collect_anthropic_config(output)
    local config = {}

    -- Max Tokens
    repeat
        io.write(string.format(output.format_1, output.max_tokens))
        io.flush()
        config.max_tokens = io.read()
    until (tonumber(config.max_tokens) >= SERVICE_CONFIG.ANTHROPIC_LIMITS.MAX_TOKENS.min)
        and (tonumber(config.max_tokens) <= SERVICE_CONFIG.ANTHROPIC_LIMITS.MAX_TOKENS.max)

    -- Thinking Type
    repeat
        io.write(string.format(output.format_1, output.type))
        io.flush()
        config.type = io.read()
    until (config.type == SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.disabled) 
        or (config.type == SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.enable)

    -- Budget Tokens (if thinking enabled)
    if config.type == SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.enable then
        repeat
            io.write(string.format(output.format_1, output.budget_tokens))
            io.flush()
            config.budget_tokens = io.read()
        until (tonumber(config.budget_tokens) >= SERVICE_CONFIG.ANTHROPIC_LIMITS.BUDGET_TOKENS.min)
            and (tonumber(config.budget_tokens) <= SERVICE_CONFIG.ANTHROPIC_LIMITS.BUDGET_TOKENS.max)
    end

    return config
end

-- Collect API key input
local function collect_api_key(args, output)
    if not args.api_key then
        io.write(string.format(output.format_1, output.api_key))
        io.flush()
        return io.read() or ""
    else
        print(string.format(output.format_2, output.api_key, args.api_key))
        return args.api_key or ""
    end
end

-- Collect model name input
local function collect_model(args, output)
    if not args.model then
        io.write(string.format(output.format_1, output.model))
        io.flush()
        return io.read() or ""
    else
        print(string.format(output.format_2, output.model, args.model))
        return args.model or ""
    end
end

-- Determine endpoint field name
local function determine_endpoint_field_name(service_name)
    return SERVICE_CONFIG.ENDPOINT_FIELDS[service_name] or "unknown"
end

-- Create UCI service section
local function create_uci_service_section(setup, endpoint_field_name)
    local unnamed_section = uci:add(common.db.uci.cfg, common.db.uci.sect.service)

    -- Basic configuration
    uci:set(common.db.uci.cfg, unnamed_section, "identifier", setup.identifier)
    uci:set(common.db.uci.cfg, unnamed_section, "name", setup.service)
    uci:set(common.db.uci.cfg, unnamed_section, endpoint_field_name, setup.endpoint)
    uci:set(common.db.uci.cfg, unnamed_section, "api_key", setup.api_key)
    uci:set(common.db.uci.cfg, unnamed_section, "model", setup.model)

    -- Endpoint type configuration
    local endpoint_type_field = SERVICE_CONFIG.ENDPOINT_TYPES[setup.service]
    if endpoint_type_field then
        uci:set(common.db.uci.cfg, unnamed_section, endpoint_type_field, common.endpoint.type.custom)
    end

    -- Anthropic-specific configuration
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

-- Main add function (refactored)
local add = function(args)
    local output = get_output_formats()

    -- Collect service configuration
    local setup = {
        identifier = common.generate_service_id("seed"),
        service = collect_service_name(args, output),
        endpoint = collect_endpoint(args, output),
        api_key = collect_api_key(args, output),
        model = collect_model(args, output)
    }

    -- Collect Anthropic-specific configuration
    if setup.service == common.ai.service.anthropic.name then
        local anthropic_config = collect_anthropic_config(output)
        setup.max_tokens = anthropic_config.max_tokens
        setup.type = anthropic_config.type
        setup.budget_tokens = anthropic_config.budget_tokens
    end

    -- Determine endpoint field name
    local endpoint_field_name = determine_endpoint_field_name(setup.service)

    -- Create UCI section
    create_uci_service_section(setup, endpoint_field_name)
end

-- Update endpoint configuration
local function update_endpoint(service_name, service_section, endpoint_value)
    local config = SERVICE_CONFIG.SERVICE_CONFIG[service_name]
    if not config then
        return false
    end

    uci:set(common.db.uci.cfg, service_section, config.endpoint_field, endpoint_value)

    if config.endpoint_type_field and config.endpoint_type_value then
        uci:set(common.db.uci.cfg, service_section, config.endpoint_type_field, config.endpoint_type_value)
    end

    return true
end

-- Update service configuration
local function update_service_config(service_section, opt)
    local updated = false

    if opt.u then
        local service_name = uci:get(common.db.uci.cfg, service_section, "name")
        if update_endpoint(service_name, service_section, opt.u) then
            updated = true
        end
    end

    if opt.k then
        uci:set(common.db.uci.cfg, service_section, "api_key", opt.k)
        updated = true
    end

    if opt.m then
        uci:set(common.db.uci.cfg, service_section, "model", opt.m)
        updated = true
    end

    if opt.s then
        uci:set(common.db.uci.cfg, service_section, "storage", opt.s)
        updated = true
    end

    return updated
end

-- Find and update service
local function find_and_update_service(identifier, opt)
    local found = false
    local updated = false

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(service)
        if service.identifier == identifier then
            found = true
            if update_service_config(service[".name"], opt) then
                updated = true
                uci:commit(common.db.uci.cfg)
            end
        end
    end)

    return found, updated
end

-- Main change function
local function change(opt, arg)
    local output = {
        service = {
            update = "Service Update!",
            not_found = "Service Not Found..."
        }
    }

    local found, updated = find_and_update_service(arg.identifier, opt)

    if found and updated then
        print(output.service.update)
    elseif not found then
        print(output.service.not_found)
    else
        print("No changes made.")
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

local select_cmd = function(arg)

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

-- Initialize and display service information
local function initialize_chat_service(arg)
    local service = common.select_service_obj()
    if not service then
        print(error_msg.load_service1 .. "\n" .. error_msg.load_service2)
        return nil
    end

    service:initialize(arg, common.ai.format.chat)
    local cfg = service:get_config()

    print("-----------------------------------")
    print(string.format("%-14s :\27[33m %s \27[0m", "Identifer", cfg.identifier))
    print(string.format("%-14s :\27[33m %s \27[0m", "AI Service", cfg.service))
    print(string.format("%-14s :\27[33m %s \27[0m", "Model", cfg.model))
    print("-----------------------------------")

    return service
end

-- Get user input
local function get_user_input(chat)
    local your_message
    repeat
        io.write("\27[32m\nYou :\27[0m")
        io.flush()
        your_message = io.read()

        if not your_message then
            return nil
        end

        if your_message == "/history" then
            chat_history(chat)
        end
    until (#your_message > 0) and (your_message ~= "/history")

    return your_message
end

-- Process message and communicate with AI
local function process_message(service, chat, message)
    if not service:setup_msg(chat, {role = common.role.user, message = message}) then
        return false
    end

    datactrl.record_chat_data(service, chat)

    local tool_info, _, tool_used = transfer.chat_with_ai(service, chat)

    debug:log("oasis.log", "process_message", "tool_used = " .. tostring(tool_used))
    debug:log("oasis.log", "process_message", "tool_info = " .. tostring(tool_info))
    if tool_info then
        debug:log("oasis.log", "process_message", "tool_info length = " .. tostring(#tool_info))
    end

    if tool_used then
        if service:handle_tool_output(tool_info, chat) then
            transfer.chat_with_ai(service, chat)
        end
    end

    return true
end

-- Main chat loop
local function chat_loop(service, chat)
    while true do
        local message = get_user_input(chat)

        if not message then
            return
        end

        if message == "/exit" then
            break
        end

        if not process_message(service, chat, message) then
            print("Error: Failed to process message")
        end
    end
end

-- Main chat function
local chat = function(arg)
    local service = initialize_chat_service(arg)
    if not service then
        return
    end

    local chat = datactrl.load_chat_data(service)
    chat_loop(service, chat)
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
            debug:log("oasis.log", "sysmsg", "arg.cmd = " .. arg.cmd)
        end

        if arg.option then
            debug:log("oasis.log", "sysmsg", "arg.option = " .. arg.option)
        end

        if arg.param then
            debug:log("oasis.log", "sysmsg", "arg.param = " .. arg.param)
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

-- Initialize service for output
local function initialize_output_service(arg)
    local service = common.select_service_obj()
    if not service then
        print(error_msg.load_service1 .. "\n" .. error_msg.load_service2)
        debug:log("oasis.log", "initialize_output_service", "[output] select_service_obj failed.")
        return nil
    end

    service:initialize(arg, common.ai.format.output)
    debug:log("oasis.log", "initialize_output_service", "[output] service.initialize done.")

    return service
end

-- Process output message
local function process_output_message(service, chat_ctx, message)

    if not service:setup_msg(chat_ctx, { role = common.role.user, message = message }) then
        return nil, nil
    end

    -- chat_with_ai returns: new_chat_info (or tool JSON when tool_used), plain_text_message, tool_used
    local new_chat_info, plain_text_message, tool_used = transfer.chat_with_ai(service, chat_ctx)

    if tool_used then
        -- Provide tool outputs back to the model, then get assistant's text reply
        if service:handle_tool_output(new_chat_info, chat_ctx) then
            local post_new_chat_info, post_message = transfer.chat_with_ai(service, chat_ctx)
            return post_new_chat_info, post_message
        else
            return nil, nil
        end
    end

    -- No tools used: return values as-is
    return new_chat_info, plain_text_message
end

-- Main output function
local output = function(arg)
    debug:log("oasis.log", "output", "\n--- [main.lua][output] ---")

    local service = initialize_output_service(arg)
    if not service then
        return nil, nil
    end

    local misc = require("oasis.chat.misc")
    os.execute("mkdir -p /tmp/oasis")

    local chat_ctx = datactrl.load_chat_data(service)
    debug:log("oasis.log", "output", "Load chat data ...")
    debug:dump("oasis.log", chat_ctx)

    local new_chat_info, plain_text_ai_message = process_output_message(service, chat_ctx, arg.message)
    -- Log returned values for diagnostics
    debug:log("oasis.log", "output", "returned new_chat_info_len=" .. tostring((new_chat_info and #new_chat_info) or 0)
        .. ", message_len=" .. tostring((plain_text_ai_message and #plain_text_ai_message) or 0))

    if new_chat_info and #new_chat_info > 0 then
        debug:log("oasis.log", "output", "new_chat_info=" .. tostring(new_chat_info))
    end

    if plain_text_ai_message and #plain_text_ai_message > 0 then
        debug:log("oasis.log", "output", "message=" .. tostring(plain_text_ai_message))
    end

    return new_chat_info, plain_text_ai_message
end

local rpc_output = function(arg)

    debug:log("oasis.log", "rpc_output", "\n--- [main.lua][rpc_output] ---")

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

    debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] Service initialize done ...")

    local rpc_output = datactrl.load_chat_data(service)

    debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] Load chat data ...")
    debug:dump("oasis.log", rpc_output)

    local new_chat_info, message = ""

    -- Once the message to be sent to the AI is prepared, write it to storage and then send it.
    if service:setup_msg(rpc_output, { role = common.role.user, message = arg.message}) then
        datactrl.record_chat_data(service, rpc_output)
    debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] record_chat_data done ...")
    new_chat_info, message = transfer.chat_with_ai(service, rpc_output)
    debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] chat_with_ai done ...")
    end

    if new_chat_info then
    debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] new_chat_info dump")
    debug:log("oasis.log", "rpc_output", new_chat_info)
    end

    debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] message = " .. message)

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
    select = select_cmd,
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
