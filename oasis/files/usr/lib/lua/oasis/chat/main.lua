#!/usr/bin/env lua
local sys               = require("luci.sys")
local util              = require("luci.util")
local uci               = require("luci.model.uci").cursor()
local jsonc             = require("luci.jsonc")
local transfer          = require("oasis.chat.transfer")
local datactrl          = require("oasis.chat.datactrl")
local common            = require("oasis.common")

local error_msg = {}
error_msg.load_service1 = "Error!\n\tOne of the service settings exist!"
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
    output.identifier       = "Identifer Name (Please enter your preferred name.)"
    output.service         = "Service (\"Ollama\" or \"OpenAI\" or \"Anthropic\" or \"Gemini\")"
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

    if (not args.identifier) then
        io.write(string.format(output.format_1, output.identifier))
        io.flush()
        setup.identifier = io.read()
    else
        print(string.format(output.format_2, output.identifier, args.service))
        setup.identifier = args.identifier
    end

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
        setup.endpoint = io.read()
    else
        print(string.format(output.format_2, output.endpoint, args.endpoint))
        setup.endpoint = args.endponit
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
        setup.api_key = io.read()
    else
        print(string.format(output.format_2, output.api_key, args.api_key))
        setup.api_key = args.api_key
    end

    if (not args.model) then
        io.write(string.format(output.format_1, output.model))
        io.flush()
        setup.model = io.read()
    else
        print(string.format(output.format_2, output.model, args.model))
        setup.model = args.model
    end

    local endpoint_op_name = "unknown"

    if setup.service == common.ai.service.ollama.name then
        endpoint_op_name = "ollama_endpoint"
    elseif setup.service == common.ai.service.openai.name then
        endpoint_op_name = "openai_endpoint"
    elseif setup.service == common.ai.service.anthropic.name then
        endpoint_op_name = "anthropic_endpoint"
    elseif setup.service == common.ai.service.gemini.name then
        endpoint_op_name = "gemini_endpoint"
    end

    local unnamed_section = uci:add(common.db.uci.cfg, common.db.uci.sect.service)
    uci:set(common.db.uci.cfg, unnamed_section, "identifier", setup.identifier)
    uci:set(common.db.uci.cfg, unnamed_section, "name", setup.service)
    uci:set(common.db.uci.cfg, unnamed_section, endpoint_op_name, setup.endpoint)
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
        if service.name == arg.service then
            is_update = true
            if opt.n then
                uci:set(common.db.uci.cfg, service[".name"], "name", opt.n)
            end
            if opt.u then
                uci:set(common.db.uci.cfg, service[".name"], "url", opt.u)
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
        io.write(string.format("%-8s >> \27[33m%s\27[0m\n", name, value))
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
                    output.item(endpoint_str, tbl.openai_endpoint)
                elseif tbl.name == common.ai.service.anthropic.name then
                    output.item(endpoint_str, tbl.anthropic_endpoint)
                elseif tbl.name == common.ai.service.gemini.name then
                    output.item(endpoint_str, tbl.gemini_endpoint)
                end
            end

            if tbl.api_key then
                output.item("API KEY", tbl.api_key)
            end

            if tbl.model then
                output.item("MODEL", tbl.model)
            end
        end
    end)
end

local delete = function(arg)

    if not arg then
        return
    end

    local output = {}
    output.service = {}
    output.service.confirm_service_delete = function(service)
        local reply

        repeat
            io.write("Do you delete service [" ..service .. "] (Y/N):")
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

    output.service.not_found = function(service)
        print("Error: Service '" .. service .. "' was not found in the configuration.")
    end

    if not arg.service then
        return
    end

    local target_section
    local found = false

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(service)
        if not found and service.name == arg.service then
            target_section = service[".name"]
            found = true
            return false
        end
    end)

    if (not target_section) or (#target_section == 0) then
        output.service.not_found(arg.service)
        return
    end

    if output.service.confirm_service_delete(arg.service) == 'N' then
        return
    end

    output.service.delete(arg.service)
end

local select = function(arg)

    if not arg.service then
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

local output = function(arg)

    if (not arg.message) then
        return
    end

    local service = common.select_service_obj()

    if not service then
        print(error_msg.load_service1 .. "\n" .. error_msg.load_service2)
        return
    end

    service:initialize(nil, common.ai.format.output)

    local output = datactrl.load_chat_data(service)

    local new_chat_info, message = ""

    -- Once the message to be sent to the AI is prepared, write it to storage and then send it.
    if service:setup_msg(output, { role = common.role.user, message = arg.message}) then
        datactrl.record_chat_data(service, output)
        new_chat_info, message = transfer.chat_with_ai(service, output)
    end

    return new_chat_info, message
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

local call = function(arg)

    local service = common.select_service_obj()

    if not service then
        print(error_msg.load_service1 .. "\n" .. error_msg.load_service2)
        return
    end

    service:initialize(nil, common.ai.format.call)
    local call = datactrl.load_chat_data(service)

    -- Once the message to be sent to the AI is prepared, write it to storage and then send it.
    if service:setup_msg(call, { role = common.role.user, message = arg.message}) then
        datactrl.record_chat_data(service, call)
        transfer.chat_with_ai(service, call)
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
    output = output,
    rename = rename,
    list = list,
    call =  call,
}
