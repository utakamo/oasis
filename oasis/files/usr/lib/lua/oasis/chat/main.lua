#!/usr/bin/env lua

local fs                = require("nixio.fs")
local util              = require("luci.util")
local uci               = require("luci.model.uci").cursor()
local jsonc             = require("luci.jsonc")
local misc              = require("oasis.chat.misc")
local transfer          = require("oasis.chat.transfer")
local datactrl          = require("oasis.chat.datactrl")
local common            = require("oasis.common")
local console           = require("oasis.console")
local ous               = require("oasis.unified.chat.schema")
local debug             = require("oasis.chat.debug")

local M = {}

local error_msg = {}
error_msg.load_service1 = "Error!\n\tThere is no AI service configuration."
error_msg.load_service2 = "\tPlease add the service configuration with the add command."

-- Clear any remaining reboot or service restart flags from the previous chat session.
-- This situation is not expected under normal conditions,
-- but the flag is cleared here as a safety measure to prevent unintended reboot requests
-- from being triggered in the current chat.
local clear_flg = function()
    os.remove(common.file.console.reboot_required)
    os.remove(common.file.console.shutdown_required)
    os.remove(common.file.service.restart_required)
end

-- Print chat history as JSON for debugging.
-- @param chat table
local chat_history = function(chat)
    console.print(#chat.messages)
    console.print()
    local chat_json = jsonc.stringify(chat, false)
    console.print(chat_json)
end

-- Interactive storage configuration (path/chat_max). Reads from args or stdin.
-- @param args table { path?: string, chat_max?: string }
function M.storage(args)

    local storage = {}
    local current_storage_path = uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "path") or ""
    local chat_max = uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "chat_max") or ""

    local function is_valid_path(p)
        return (type(p) == "string") and p:match("^[%w%._/-]+$")
    end

    local output = {}
    output.error = {}
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

    console.print(output.title.current)
    console.print(string.format(output.format_1, "path", current_storage_path))
    console.print(string.format(output.format_1, "chat-max", chat_max))
    console.print()
    console.print(output.title.setup)
    console.print(output.title.input)

    if (not args.path) then
        console.printf(output.format_2, output.path)
        console.flush()
        storage.path = console.read() or ""
    else
        console.print(string.format(output.format_1, "path", args.path))
        storage.path = args.path
    end

    if (not args.chat_max) then
        console.printf(output.format_2, output.chat_max)
        console.flush()
        storage.chat_max = console.read() or ""
    else
        console.print(string.format(output.format_1, "chat-max", args.chat_max))
        storage.chat_max = args.chat_max
    end

    if #storage.path > 0 then
        local prefix = (uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "prefix") or "")

        if (#current_storage_path == 0) or (#prefix == 0) then
            console.print(output.error.config)
            return
        end

        if is_valid_path(storage.path) then
            -- ensure destination exists
            fs.mkdirr(storage.path)

            -- move only files that start with prefix from current_storage_path to storage.path
            local function safe_join(dir, name)
                if dir:sub(-1) ~= "/" then dir = dir .. "/" end
                return dir .. name
            end

            for name in (fs.dir(current_storage_path) or function() return nil end) do
                -- skip special entries
                if name ~= "." and name ~= ".." then
                    -- only plain filename characters
                    if name:match("^[%w%._%-]+$") and name:sub(1, #prefix) == prefix then
                        local src = safe_join(current_storage_path, name)
                        local dst = safe_join(storage.path, name)
                        -- try rename first (same filesystem), fallback to copy+remove
                        if not fs.rename(src, dst) then
                            if misc.copy_file(src, dst) then
                                os.remove(src)
                            end
                        end
                    end
                end
            end
        else
            console.print(output.error.path)
            return
        end

        uci:set(common.db.uci.cfg, common.db.uci.sect.storage, "path", storage.path)
    end

    if storage.chat_max and (#storage.chat_max > 0) then
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
        common.ai.service.gemini.name,
        common.ai.service.openrouter.name,
        common.ai.service.lmstudio.name
    },

    ENDPOINT_FIELDS = {
        [common.ai.service.ollama.name] = "ollama_endpoint",
        [common.ai.service.openai.name] = "openai_custom_endpoint",
        [common.ai.service.anthropic.name] = "anthropic_custom_endpoint",
        [common.ai.service.gemini.name] = "gemini_custom_endpoint",
        [common.ai.service.openrouter.name] = "openrouter_custom_endpoint",
        [common.ai.service.lmstudio.name] = "lmstudio_endpoint"
    },

    ENDPOINT_TYPES = {
        [common.ai.service.openai.name] = "openai_endpoint_type",
        [common.ai.service.anthropic.name] = "anthropic_endpoint_type",
        [common.ai.service.gemini.name] = "gemini_endpoint_type",
        [common.ai.service.openrouter.name] = "openrouter_endpoint_type"
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
        },
        [common.ai.service.openrouter.name] = {
            endpoint_field = "openrouter_custom_endpoint",
            endpoint_type_field = "openrouter_endpoint_type",
            endpoint_type_value = common.endpoint.type.custom
        },
        [common.ai.service.lmstudio.name] = {
            endpoint_field = "lmstudio_endpoint",
            endpoint_type_field = nil,
            endpoint_type_value = nil
        }
    }
}

-- Output format definitions
local function get_output_formats()
    local output = {}

    -- Basic formats
    output.format_1 = "%-64s >> "
    output.format_2 = "%-64s >> %s"

    -- Supported services header
    local service_names = {}
    for _, name in ipairs(SERVICE_CONFIG.VALID_SERVICES or {}) do
        table.insert(service_names, name)
    end
    output.supported_title = "[Supported AI Service LIst]"
    output.supported_line = table.concat(service_names, ", ")

    -- Field labels
    output.service = "AI Service Name"
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
            if #setup.service == 0 then
                os.exit()
            end
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
        console.printf(output.format_1, output.endpoint)
        console.flush()
        return console.read() or ""
    else
        console.print(string.format(output.format_2, output.endpoint, args.endpoint))
        return args.endpoint or ""
    end
end

-- Collect Anthropic-specific configuration
local function collect_anthropic_config(output)
    local config = {}

    -- Max Tokens
    repeat
        console.printf(output.format_1, output.max_tokens)
        console.flush()
        config.max_tokens = console.read()
    until (tonumber(config.max_tokens) >= SERVICE_CONFIG.ANTHROPIC_LIMITS.MAX_TOKENS.min)
        and (tonumber(config.max_tokens) <= SERVICE_CONFIG.ANTHROPIC_LIMITS.MAX_TOKENS.max)

    -- Thinking Type
    repeat
        console.printf(output.format_1, output.type)
        console.flush()
        config.type = console.read()
    until (config.type == SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.disabled)
        or (config.type == SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.enabled)

    -- Budget Tokens (if thinking enabled)
    if config.type == SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.enabled then
        repeat
            console.printf(output.format_1, output.budget_tokens)
            console.flush()
            config.budget_tokens = console.read()
        until (tonumber(config.budget_tokens) >= SERVICE_CONFIG.ANTHROPIC_LIMITS.BUDGET_TOKENS.min)
            and (tonumber(config.budget_tokens) <= SERVICE_CONFIG.ANTHROPIC_LIMITS.BUDGET_TOKENS.max)
    end

    return config
end

-- Collect API key input
local function collect_api_key(args, output)
    if not args.api_key then
        console.printf(output.format_1, output.api_key)
        console.flush()
        return console.read() or ""
    else
        console.print(string.format(output.format_2, output.api_key, args.api_key))
        return args.api_key or ""
    end
end

-- Collect model name input
local function collect_model(args, output)
    if not args.model then
        console.printf(output.format_1, output.model)
        console.flush()
        return console.read() or ""
    else
        console.print(string.format(output.format_2, output.model, args.model))
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
-- Add a new AI service configuration interactively or from args.
-- @param args table
function M.add(args)
    local output = get_output_formats()

    -- Show supported services first
    print(output.supported_title)
    print(output.supported_line)

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
        -- Persist 'thinking' for UI compatibility; keep 'type' for backward compatibility
        if anthropic_config.type == SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.enabled then
            setup.thinking = SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.enabled
        else
            setup.thinking = SERVICE_CONFIG.ANTHROPIC_LIMITS.THINKING_TYPES.disabled
        end
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

local get_service_id_by_number = function(arg)
    local index = 0
    local target_section = ""
    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(service)
        index = index + 1
        if tonumber(arg.no) == index then
            target_section = service[".name"]
        end
    end)

    return target_section
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
local function find_and_update_service(arg, opt)

    local is_found = false
    local is_update = false
    local index = 0

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(service)
        index = index + 1
        if tonumber(arg.no) == index then
            debug:log("oasis.log", "find_and_update_service", "identifier = " .. service.identifier)
            arg.identifier = service.identifier
            if update_service_config(service[".name"], opt) then
                uci:commit(common.db.uci.cfg)
                debug:log("oasis.log", "find_and_update_service", "updated!!")
                is_found = true
                is_update = true
            else
                debug:log("oasis.log", "find_and_update_service", "not updated ...")
                is_found = true
                is_update = false
            end
        end
    end)

    return is_found, is_update
end

-- Main change function
-- Change an existing AI service by numeric index with options.
-- @param arg table { no: string }
-- @param opt table { u?: string, k?: string, m?: string, s?: string }
function M.change(arg, opt)

    local output = {
        service = {
            update = "Service Update!",
            not_found = "Service Not Found..."
        }
    }

    local is_found, is_update = find_and_update_service(arg, opt)

    if is_found and is_update then
        console.print(output.service.update)
    elseif not is_found then
        console.print(output.service.not_found)
    else
        console.print("No changes made.")
    end
end

-- Show configured AI services.
function M.show_service_list()

    local output = {}
    output.service = {}

    output.service.in_use = function(no)
        console.print("\n\27[1;34mService No: " .. no .. " \27[1;32m(in use)\27[0m")
    end

    output.service.not_in_use = function(no)
        console.print("\n\27[1;34mService No: " .. no .. "\27[0m")
    end

    output.line = function()
        console.print("-----------------------------------------------")
    end

    output.item = function(name, value)
        local display_value = value or "(not set)"
        if (name == "API KEY") and value then
            console.printf("%-8s >> \27[33m%s\27[0m\n", name, "******************************")
        else
            console.printf("%-8s >> \27[33m%s\27[0m\n", name, display_value)
        end
        console.flush()
    end

    local index = 0

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(tbl)
        index = index + 1
        if tbl.name then
            if index == 1 then
                output.service.in_use(index)
            else
                output.service.not_in_use(index)
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
                elseif tbl.name == common.ai.service.lmstudio.name then
                    output.item(endpoint_str, tbl.lmstudio_endpoint)
                end
            end

            output.item("API KEY", tbl.api_key)
            output.item("MODEL", tbl.model)
        end
    end)
end

-- Delete service by numeric index (asks for confirmation).
-- @param arg table { no: string }
function M.delete(arg)

    if not arg then
        return
    end

    local output = {}
    output.service = {}
    output.service.confirm_service_delete = function(no)
        local reply

        repeat
            io.write("Do you delete Service No." .. no .. " (Y/N):")
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

    output.service.not_found = function(no)
        print("Error: Service No." .. no .. " was not found in the configuration.")
    end

    local target_section = get_service_id_by_number(arg)

    if (#target_section == 0) then
        output.service.not_found(arg.no)
        return
    end

    if output.service.confirm_service_delete(arg.no) == 'N' then
        return
    end

    output.service.delete(target_section)
end

-- Select service by numeric index (reorder to first).
-- @param arg table { no: string }
function M.select(arg)

    if not arg.no then
        return
    end

    local target_section = get_service_id_by_number(arg)

    if #target_section == 0 then
        console.print("Service No: " .. arg.no .. " is not found.")
        return
    end

    -- swap section data
    uci:reorder(common.db.uci.cfg, target_section, 1)
    uci:commit(common.db.uci.cfg)

    local model = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "model")
    console.print("Service No: " .. arg.no .. " is selected.")
    console.print("Target model: \27[33m" .. model .. "\27[0m")
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

    console.print("-----------------------------------")
    console.print(string.format("%-14s :\27[33m %s \27[0m", "AI Service", cfg.service))
    console.print(string.format("%-14s :\27[33m %s \27[0m", "Model", cfg.model))
    console.print("-----------------------------------")

    return service
end

local function judge_system_reboot()

    if not misc.check_file_exist(common.file.console.reboot_required) then
        return
    end

    console.write("\nSystem Reboot [Y/N]: ")
    console.flush()

    local reply = console.read()
    if reply == "Y" then
        os.execute("reboot")
    else
        os.remove(common.file.console.reboot_required)
        return
    end

    console.write("\n")

    os.remove(common.file.console.reboot_required)
    os.exit(0)
end

local function judge_system_shutdown()

    if not misc.check_file_exist(common.file.console.shutdown_required) then
        return
    end

    console.write("\nSystem Shutdown [Y/N]: ")
    console.flush()

    local reply = console.read()
    if reply == "Y" then
        local cmd = require("oasis.local.tool.system.command")
        cmd.system_shutdown_after_5sec()
    else
        os.remove(common.file.console.shutdown_required)
        return
    end

    console.write("\n")

    os.remove(common.file.console.shutdown_required)
    os.exit(0)
end

local function judge_service_restart()

	local path = common.file.service.restart_required
    local is_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")

    if not is_tool then
        os.remove(path)
        return
    end

	if not misc.check_file_exist(path) then
		return
	end

	local svc = misc.read_file(path) or ""
	svc = svc:gsub("%s+$", "")
	if #svc == 0 then
		os.remove(path)
		return
	end

    console.write("\nRestart Service (" .. svc .. ") [Y/N]: ")
    console.flush()

    local reply = console.read()
	if reply == "Y" then
        local cmd = require("oasis.local.tool.system.command")
        cmd.restart_service_after_3sec(svc)

        console.print("\nService restart will start in 3 seconds.")
	end

    console.write("\n")
	os.remove(path)
end

-- Get user input
local function get_user_input(chat)
    local your_message
    repeat
        judge_system_shutdown()
        judge_system_reboot()
        judge_service_restart()
        console.write("\27[32m\nYou :\27[0m")
        console.flush()
        your_message = console.read()

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

    -- Per-chat turn limit: block when user message count reached chat_max
    local function is_turns_exceeded_for_chat(data)
        local max = tonumber(uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "chat_max") or "0") or 0
        if max <= 0 then return false end
        local cnt = 0
        for _, m in ipairs(data.messages or {}) do
            if m.role == common.role.user then cnt = cnt + 1 end
        end
        debug:log("oasis.log", "process_message", "cnt = " .. cnt .. ", max = " .. max)
        return cnt >= max
    end

    if is_turns_exceeded_for_chat(chat) then
        return false, "maximum chat turns reached for this chat"
    end

    if not ous.setup_msg(service, chat, {role = common.role.user, message = message}) then
        debug:log("oasis.log", "process_message", "setup message error")
        return false, "setup message error"
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
        else
            return false, "failed to handle tool output"
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

        local ok, err = process_message(service, chat, message)
        if not ok then
            console.print("\27[31mError: " .. (err or "Failed to process message") .. "\27[0m")
        end
    end
end

local display_chat_history = function(chat)
    for _, tbl in ipairs(chat.messages) do
        if tbl.role == common.role.user then
            console.print("\27[32m\nYou :\27[0m" .. tbl.content)
        elseif tbl.role == common.role.assistant then

            local content = misc.markdown(nil, tbl.content)

            console.print()
            console.print("\27[34m" .. chat.model .. "\27[0m")
            console.print(content)
        end
    end
end

local get_chat_data_by_number = function(arg)

    if not arg.no then
        return nil
    end

    local list = util.ubus("oasis.chat", "list", {})

    for chat_no, chat_info in ipairs(list.item) do
        debug:log("oasis.log", "get_chat_data_by_number", "chat_info.id = " .. chat_info.id)
        debug:log("oasis.log", "get_chat_data_by_number", "arg.no = " .. arg.no)
        debug:log("oasis.log", "get_chat_data_by_number", "chat_no = " .. chat_no)
        if tonumber(arg.no) == chat_no then
            return chat_info.id
        end
    end

    return nil
end

-- Main chat function
-- Start interactive chat for selected chat number.
-- @param arg table { no?: string }
function M.chat(arg)

    arg.id = get_chat_data_by_number(arg)

    local service = initialize_chat_service(arg)

    if not service then
        return
    end

    local chat = datactrl.load_chat_data(service)
    display_chat_history(chat)
    chat_loop(service, chat)
end

-- Delete chat data by chat number.
-- @param arg table { no: string }
function M.delchat(arg)

    arg.id = get_chat_data_by_number(arg)

    if arg.id then
        console.write("Do you delete chat data no=" ..arg.no .. " ? (Y/N):")
        console.flush()

        local reply = console.read()

        if reply == 'N' then
            console.print("canceled.")
            return
        end
    else
        console.print("No chat data found for no=" .. arg.no)
        return
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

    console.print("Delete chat data no=" .. arg.no)
end

-- One-shot prompt command: prints assistant reply to console.
-- @param arg table { message: string }
function M.prompt(arg)

    local service = common.select_service_obj()

    clear_flg()

    if not service then
        print(error_msg.load_service1 .. "\n" .. error_msg.load_service2)
        return
    end

    service:initialize(arg, common.ai.format.prompt)

    -- In the case of the prompt command, the load_chat_data function is used to return template-structured data conforming to the Oasis unified chat schema.
    local prompt = datactrl.load_chat_data(service)

    -- Once the message to be sent to the AI is prepared, write it to storage and then send it.
    if not ous.setup_msg(service, prompt, {role = common.role.user, message = arg.message}) then
        return false
    end

    local tool_info, _, tool_used = transfer.chat_with_ai(service, prompt)
    console.print()

    debug:log("oasis.log", "prompt", "tool_used = " .. tostring(tool_used))
    debug:log("oasis.log", "prompt", "tool_info = " .. tostring(tool_info))
    if tool_info then
        debug:log("oasis.log", "prompt", "tool_info length = " .. tostring(#tool_info))
    end

    if tool_used then
        if service:handle_tool_output(tool_info, prompt) then
            transfer.chat_with_ai(service, prompt)
            print()
        end
    end

    judge_system_shutdown()
    judge_system_reboot()
    judge_service_restart()
end

-- Manage system messages: list/select/create.
-- @param arg table
function M.sysmsg(arg)

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
        console.print()

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

    -- Select system message key
    if (arg.option == "-s") and arg.param then
        local category, target = arg.param:match("^([^.]+)%.([^.]+)$")
        if (category and target) and (sysmsg[category]) and (sysmsg[category][target]) then
            uci:set(common.db.uci.cfg, common.db.uci.sect.console, arg.cmd, arg.param)
            uci:commit(common.db.uci.cfg)
            print(arg.cmd .. " command ---> " .. arg.param)
        else
            print("Not Found ...")
        end

    -- Create new system message data
    elseif (arg.option == "-c") and (arg.param) then

        -- Add a new custom section with next index: custom_(max+1)
        local max_suffix = 0
        for key, _ in pairs(sysmsg) do
            local s = tonumber(key:match("^custom_(%d+)$"))
            if s and (s > max_suffix) then
                max_suffix = s
            end
        end

        local category = "custom_" .. (max_suffix + 1)
        sysmsg[category] = sysmsg[category] or {}
        sysmsg[category][arg.cmd] = arg.param

        local is_update = common.update_conf_file("/etc/oasis/oasis.conf", sysmsg)

        if not is_update then
            print("error!")
        end

        print("Update Success!!  (added " .. category .. ")")
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

    if not ous.setup_msg(service, chat_ctx, { role = common.role.user, message = message }) then
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
-- Output mode: returns (new_chat_info, message).
-- @param arg table { message: string }
-- @return string|nil, string|nil
function M.output(arg)
    debug:log("oasis.log", "output", "\n--- [main.lua][output] ---")

    local service = initialize_output_service(arg)
    if not service then
        return nil, nil
    end

    clear_flg()

    os.execute("mkdir -p /tmp/oasis")

    local chat_ctx = datactrl.load_chat_data(service)
    debug:log("oasis.log", "output", "Load chat data ...")
    -- debug:dump("oasis.log", chat_ctx)

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

-- RPC output mode for ubus: returns (status_tbl, new_chat_info, message, reboot).
-- @param arg table { message: string }
-- @return table, string|nil, string|nil, boolean
function M.rpc_output(arg)

    debug:log("oasis.log", "rpc_output", "\n--- [main.lua][rpc_output] ---")

    local enable = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.rpc, "enable")

    if not enable then
        return { status = common.status.error, desc = "Oasis's RPC function is not enabled." }
    end

    if not arg then
        return { status = common.status.error, desc = "No argument." }, nil, nil
    end

    local service = common.select_service_obj()

    clear_flg()

    if not service then
        return { status = common.status.error, desc = "AI Service Not Found." }, nil, nil
    end

    service:initialize(arg, common.ai.format.rpc_output)

    debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] Service initialize done ...")

    local chat_ctx = datactrl.load_chat_data(service)

    -- debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] Load chat data ...")
    -- debug:dump("oasis.log", chat_ctx)

    local new_chat_info, message = nil, nil
    local status_tbl = { status = common.status.ok }
    local tool_info = nil
    local shutdown = false

    -- Once the message to be sent to the AI is prepared, write it to storage and then send it.
    if ous.setup_msg(service, chat_ctx, { role = common.role.user, message = arg.message}) then
        datactrl.record_chat_data(service, chat_ctx)
        debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] record_chat_data done ...")

        -- First call
        local first, plain_text, tool_used = transfer.chat_with_ai(service, chat_ctx)

        if tool_used then
            -- Keep tool JSON for external device
            tool_info = first
            -- Provide tool outputs back to model
            if service:handle_tool_output(tool_info, chat_ctx) then
                -- Second call to get assistant text (and possibly new chat info)
                local post_new_chat_info, post_message = transfer.chat_with_ai(service, chat_ctx)
                new_chat_info, message = post_new_chat_info, post_message
            else
                return { status = common.status.error, desc = "failed to handle tool output" }, nil, nil
            end
        else
            -- No tools used
            new_chat_info, message = first, plain_text
        end

        debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] chat_with_ai done ...")
    end

    if new_chat_info then
        debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] new_chat_info dump")
        debug:log("oasis.log", "rpc_output", new_chat_info)
    end

    debug:log("oasis.log", "rpc_output", "[main.lua][rpc_output] message = " .. tostring(message))

    -- Attach tool_info for external device consumption (backward compatible)
    if tool_info then
        status_tbl.tool_info = tool_info
        local parsed = jsonc.parse(tool_info)
        if parsed and parsed.shutdown == true then
            shutdown = true
        end
    end

    local reboot = false
    if service.get_reboot_required then
        reboot = service:get_reboot_required() or false
    end
    status_tbl.shutdown = shutdown
    return status_tbl, new_chat_info, message, reboot
end

-- Rename chat title by chat number.
-- @param arg table { no: string, title: string }
function M.rename(arg)

    arg.id = get_chat_data_by_number(arg)

    if not arg.id then
        print("Chat data for no=" .. arg.no .. " could not be found.")
        return
    end

    local result = util.ubus("oasis.title", "manual_set", {id = arg.id, title = arg.title})

    if result.status == "OK" then
        print("Changed title of chat data with no=" .. arg.no  .. " to " .. result.title .. ".")
    end
end

-- List chat titles with indices.
function M.list()

    local list = util.ubus("oasis.chat", "list", {})

    if #list.item == 0 then
        print("No chat file ...")
        return
    end

    print("-------------------------------------------------------------")
    print(string.format(" %3s | title", "No." ))
    print("-------------------------------------------------------------")

    for i, chat_info in ipairs(list.item) do
        print(string.format("%3d: %s", i, chat_info.title))
    end
end

-- Manage local tools (enable/disable) when oasis-mod-tool is available.
function M.tools()

	local is_local_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
	if not is_local_tool then
		print("This command is exclusive to oasis-mod-tool.")
        print("Please install oasis-mod-tool to use it.")
		return
	end

	local by_server = {}
	uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
		local server = s.server or "-"
		if not by_server[server] then by_server[server] = {} end
		table.insert(by_server[server], {
			name   = s.name or "-",
			enable = s.enable or "0",
			conflict = s.conflict or "0",
			sect   = s[".name"]
		})
	end)

	local servers = {}
	for srv, _ in pairs(by_server) do table.insert(servers, srv) end
	table.sort(servers)

	local index_map = {}
	local idx = 0

	for _, server in ipairs(servers) do
		print("- " .. server)
		table.sort(by_server[server], function(a, b) return (a.name or "") < (b.name or "") end)
		for _, t in ipairs(by_server[server]) do
			idx = idx + 1
			local status = (t.enable == "1") and "enable" or "disable"
            local status_text_color = "\27[33m"
            if status == "enable" then
                status_text_color = "\27[32m"
            end
			local conflict_suffix = (t.conflict == "1") and " [conflict]" or ""
			print(string.format(" %3d: %-30s - %s%s\27[0m\27[31m%s\27[0m", idx, t.name, status_text_color, status, conflict_suffix))
			index_map[idx] = { sect = t.sect, name = t.name }
		end
		print()
	end

	if idx == 0 then
		print("No tools found.")
		return
	end

	io.write("Would you like to enable or disable a tool? (E/D/N): ")
	io.flush()
	local ans = io.read()
	if (ans == "N") or (ans == "n") then
		return
	end
	local action
	if (ans == "E") or (ans == "e") then
		action = "enable"
	elseif (ans == "D") or (ans == "d") then
		action = "disable"
	else
		print("Canceled.")
		return
	end

	io.write("Target Tool No: ")
	io.flush()
	local num = tonumber(io.read())
	if (not num) or (not index_map[num]) then
		print("Invalid number.")
		return
	end

	local sect = index_map[num].sect
	if action == "enable" then
		local conflict = uci:get(common.db.uci.cfg, sect, "conflict")
		if conflict == "1" then
			print("Cannot enable this tool due to conflict.")
			return
		end
		uci:set(common.db.uci.cfg, sect, "enable", "1")
		uci:commit(common.db.uci.cfg)
		print("\n Enabled tool: " .. index_map[num].name)
	else
		uci:set(common.db.uci.cfg, sect, "enable", "0")
		uci:commit(common.db.uci.cfg)
		print("\n Disabled tool: " .. index_map[num].name)
	end
end

return M
