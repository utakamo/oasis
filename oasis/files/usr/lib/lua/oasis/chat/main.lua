#!/usr/bin/env lua
local sys = require("luci.sys")
local util = require("luci.util")
local uci = require("luci.model.uci").cursor()
local jsonc = require("luci.jsonc")
local transfer = require("oasis.chat.transfer")
local datactrl = require("oasis.chat.datactrl")
local common = require("oasis.common")

local sysmsg_info = {}
sysmsg_info.fix_key = {}
sysmsg_info.fix_key.casual = "casual"

local push_chat_data_for_record = function(chat, speaker)

    local service = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "name", "")

    if (not speaker.role) or (not speaker.message) or (#speaker.message == 0) then
        return
    end

    if (service == common.ai.service.ollama.name)
        or (service == common.ai.service.openai.name)
        or (service == common.ai.service.anthropic.name) then

        chat.messages[#chat.messages + 1] = {}
        chat.messages[#chat.messages].role = speaker.role
        chat.messages[#chat.messages].content = speaker.message

    elseif service == common.ai.service.gemini.name then
        -- todo: fix
        chat.messages[#chat.messages + 1] = {}
        chat.messages[#chat.messages].role = speaker.role
        chat.messages[#chat.messages].content = speaker.message
    end

    -- add new ai service [template]
    --[[
    elseif service == common.ai.service.new-ai-service.name then

        if (not speaker.role) or (not speaker.message) or (#speaker.message == 0) then
            return
        end

        chat.messages[#chat.messages + 1] = {}
        chat.messages[#chat.messages].role = speaker.role
        chat.messages[#chat.messages].content = speaker.message
    end
    ]]
end

local create_chat_file = function(service, chat)
    -- TODO:
    -- Update to allow chat files to be created even when role:system is not present.
    local message = {}
    if (service.sysmsg_key) and (#service.sysmsg_key > 0) and (service.sysmsg_key == sysmsg_info.fix_key.casual) then
        -- os.execute("echo \"no system message\" >> /tmp/oasis-create-chat-file.log")
        message.role1 = chat.messages[#chat.messages - 1].role
        message.content1 = chat.messages[#chat.messages - 1].content
        message.role2 = chat.messages[#chat.messages].role
        message.content2 = chat.messages[#chat.messages].content
        message.role3 = ""
        message.content3 = ""
    else
        -- os.execute("echo \"system message\" >> /tmp/oasis-create-chat-file.log")
        message.role1 = chat.messages[#chat.messages - 2].role
        message.content1 = chat.messages[#chat.messages - 2].content
        message.role2 = chat.messages[#chat.messages - 1].role
        message.content2 = chat.messages[#chat.messages - 1].content
        message.role3 = chat.messages[#chat.messages].role
        message.content3 = chat.messages[#chat.messages].content
    end

    -- os.execute("echo " .. message.role1 .. " >> /tmp/oasis-message.log")
    -- os.execute("echo \"" .. message.content1 .. "\" >> /tmp/oasis-message.log")
    -- os.execute("echo " .. message.role2 .. " >> /tmp/oasis-message.log")
    -- os.execute("echo \"" .. message.content2 .. "\" >> /tmp/oasis-message.log")
    -- os.execute("echo " .. message.role3 .. " >> /tmp/oasis-message.log")
    -- os.execute("echo \"" .. message.content3 .. "\" >> /tmp/oasis-message.log")

    local result = util.ubus("oasis.chat", "create", message)
    service.id = result.id
    return result.id
end

local set_chat_title = function(chat_id)
    local request = util.ubus("oasis.title", "auto_set", {id = chat_id})
    local announce =  "\n" .. "\27[1;37;44m" .. "Title:"
    announce = announce  .. "\27[1;33;44m" .. request.title
    announce = announce .. "  \27[1;37;44m" .. "ID:"
    announce = announce .. "\27[1;33;44m" .. chat_id
    announce = announce .. "\27[0m"
    io.write("\n" .. announce .. "\n")
    io.flush()
end

local append_chat_data = function(service, chat)
    local message = {}
    local ai_service = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "name")

    if (ai_service == common.ai.service.ollama.name)
        or (ai_service == common.ai.service.openai.name)
        or (ai_service == common.ai.service.anthropic.name) then
        message.id = service.id
        message.role1 = chat.messages[#chat.messages - 1].role
        message.content1 = chat.messages[#chat.messages - 1].content
        message.role2 = chat.messages[#chat.messages].role
        message.content2 = chat.messages[#chat.messages].content
    elseif ai_service == common.ai.service.gemini.name then
        -- todo
        message.id = service.id
        message.role1 = chat.messages[#chat.messages - 1].role
        message.content1 = chat.messages[#chat.messages - 1].content
        message.role2 = chat.messages[#chat.messages].role
        message.content2 = chat.messages[#chat.messages].content
    end
    util.ubus("oasis.chat", "append", message)
end

local record_chat_data = function(service, chat)

    -- print("#chat.messages = " .. #chat.messages)

    -- First Conversation (#chat.messages == 3)
    -- chat.messages[1] ... system message
    -- chat.messages[2] ... user message
    -- chat.messages[3] ... ai message <---- Save chat data

    -- Conversation after the second (#chat.messages >= 5) and ((#chat.messages % 2) == 1)
    -- chat.messages[4] ... user message
    -- chat.messages[5] ... ai message <---- Save chat data
    -- chat.messages[6] ... user message
    -- chat.messages[7] ... ai message <---- Save chat data

    -- First Conversation
    if #chat.messages == 3 then
        local chat_id = create_chat_file(service, chat)
        set_chat_title(chat_id)
    -- Conversation after the second
    elseif (#chat.messages >= 5) and ((#chat.messages % 2) == 1) then
        append_chat_data(service, chat)
    end
end

local chat_history = function(chat)
    print(#chat.messages)
    print()
    local chat_json = jsonc.stringify(chat, false)
    print(chat_json)
end

local communicate = function(cfg, chat, format)

    local service = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "name", "")
    local spath = uci:get(common.db.uci.cfg, common.db.uci.sect.role, "path")
    local sysrole = common.load_conf_file(spath)

    -- chat ..... chat mode for cui
    if (format == common.ai.format.chat) and ((not cfg.id) or (#cfg.id == 0)) then
        if (service == common.ai.service.ollama.name) or (service == common.ai.service.openai.name) then
            table.insert(chat.messages, 1, {
                role = common.role.system,
                content = string.gsub(sysrole.default.chat, "\\n", "\n")
            })
        elseif service == common.ai.service.anthropic.name then
            table.insert(chat, 1, {
                system = string.gsub(sysrole.default.chat, "\\n", "\n")
            })
        elseif service == common.ai.service.gemini.name then
            table.insert(chat.messages, 1, {
                role = common.role.system,
                content = string.gsub(sysrole.default.chat, "\\n", "\n")
            })
        end
    -- output ... chat mode for luci
    elseif (format == common.ai.format.output) and ((not cfg.id) or (#cfg.id == 0)) then
        if (cfg.sysmsg_key) and (#cfg.sysmsg_key > 0) and (cfg.sysmsg_key ~= sysmsg_info.fix_key.casual) then
            if (service == common.ai.service.ollama.name) or (service == common.ai.service.openai.name) then
                table.insert(chat.messages, 1, {
                    role = common.role.system,
                    content = string.gsub(sysrole[cfg.sysmsg_key].chat, "\\n", "\n")
                })
            elseif service == common.ai.service.anthropic.name then
                table.insert(chat, 1, {
                    system = string.gsub(sysrole[cfg.sysmsg_key].chat, "\\n", "\n")
                })
            elseif service == common.ai.service.gemini.name then
                table.insert(chat.messages, 1, {
                    role = common.role.system,
                    content = string.gsub(sysrole[cfg.sysmsg_key].chat, "\\n", "\n")
                })
            end
        end
    -- prompt ... prompt mode for cui
    elseif format == common.ai.format.prompt then
        if (service == common.ai.service.ollama.name) or (service == common.ai.service.openai.name) then
            table.insert(chat.messages, 1, {
                role = common.role.system,
                content = string.gsub(sysrole.default.prompt, "\\n", "\n")
            })
        elseif service == common.ai.service.anthropic.name then
            table.insert(chat, 1, {
                system = string.gsub(sysrole.default.prompt, "\\n", "\n")
            })
        elseif service == common.ai.service.gemini.name then
            table.insert(chat.messages, 1, {
                role = common.role.system,
                content = string.gsub(sysrole.default.prompt, "\\n", "\n")
            })
        end
    -- call ... script call mode for cui
    elseif format == common.ai.format.call then
        if (service == common.ai.service.ollama.name) or (service == common.ai.service.openai.name) then
            table.insert(chat.messages, 1, {
                role = common.role.system,
                content = string.gsub(sysrole.default.call, "\\n", "\n")
            })
        elseif service == common.ai.service.anthropic.name then
            table.insert(chat, 1, {
                system = string.gsub(sysrole.default.call, "\\n", "\n")
            })
        elseif service == common.ai.service.gemini.name then
            table.insert(chat.messages, 1, {
                role = common.role.system,
                content = string.gsub(sysrole.default.call, "\\n", "\n")
            })
        end
    end

    --os.execute("echo sendyyy >> /tmp/send-oasis.log")

    if format == common.ai.format.chat then
        print("\n\27[34m" .. chat.model .. "\27[0m")
    end

    local user_msg_str = jsonc.stringify(chat, false)

    local recv_ai_msg = transfer.send_user_msg(cfg, format, user_msg_str)

    -- debug
    -- for key, val in pairs(recv_ai_msg) do
    --     os.execute("echo \"" .. key .. val .. "\" >> /tmp/oasis-recv.log")
    -- end

    local new_chat_info = nil

    if format == common.ai.format.chat then
        -- print("#ai.message = " .. #ai.message)
        -- print("ai.message = " .. ai.message)
        if (recv_ai_msg.role ~= common.role.unknown) and (#recv_ai_msg.message > 0) then
            push_chat_data_for_record(chat, recv_ai_msg)
            record_chat_data(cfg, chat)
        end
    elseif format == common.ai.format.output then
        if (recv_ai_msg.role ~= common.role.unknown) and (#recv_ai_msg.message > 0) then

            -- debug start
            --[[
            os.execute("echo " .. cfg.id .. " >> /tmp/oasis-id1.log")
            os.execute("echo #cfg.id = " .. #cfg.id .. " >> /tmp/oasis.log")
            os.execute("echo \"ai.message = " .. recv_ai_msg.message .. "\" >> /tmp/oasis-ai.log")

            if (not cfg.id) then
                os.execute("echo not cfg.id >> /tmp/oasis.log")
            else
                os.execute("echo cfg.id exist >> /tmp/oasis.log")
            end
            ]]
            -- debug end

            if (not cfg.id) or (#cfg.id == 0) then
                push_chat_data_for_record(chat, recv_ai_msg)
                local chat_info = {}
                chat_info.id = create_chat_file(cfg, chat)
                local result = util.ubus("oasis.title", "auto_set", {id = chat_info.id})
                chat_info.title = result.title
                new_chat_info = jsonc.stringify(chat_info, false)
            else
                push_chat_data_for_record(chat, recv_ai_msg)
                append_chat_data(cfg, chat)
            end
        end
    end

    return new_chat_info, recv_ai_msg.message
end

local storage = function(args)

    local storage = {}
    local current_storage_path = uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "path")
    local chat_max = uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "chat_max")

    print("[Current Storage Config]")
    print(string.format("%-30s >> %s", "path", current_storage_path))
    print(string.format("%-30s >> %s\n", "chat-max", chat_max))

    print("[Setup New Storage Config]")
    print("please input new config!")

    if (not args.path) then
        io.write(string.format("%-30s >> ", "path (Blank if not change)"))
        io.flush()
        storage.path = io.read()
    else
        print(string.format("%-30s >> %s", "path", args.path))
        storage.path = args.path
    end

    if (not args.chat_max) then
        io.write(string.format("%-30s >> ", "chat-max (Blank if not change)"))
        io.flush()
        storage.chat_max = io.read()
    else
        print(string.format("%-30s >> %s", "chat-max", args.chat_max))
        storage.chat_max = args.chat_max
    end

    if #storage.path > 0 then
        local prefix = uci:get(common.db.uci.cfg, common.db.uci.sect.storage, "prefix")

        if (#current_storage_path == 0) or (#prefix == 0) then
            print("Error! Failed to load configuration information.")
            return
        end

        if storage.path:match("^[%w/]+$") then
            sys.exec("mv " .. current_storage_path .. "/" .. prefix .. "* " .. storage.path)
        else
            print("Error! Invalid directory path.")
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

    if (not args.service) then
        io.write(string.format("%-30s >> ", "Service Name"))
        io.flush()
        setup.service = io.read()
    else
        print(string.format("%-30s >> %s", "Service Name", args.service))
        setup.service = args.service
    end

    if (not args.url) then
        io.write(string.format("%-30s >> ", "Endpoint(url)"))
        io.flush()
        setup.url = io.read()
    else
        print(string.format("%-30s >> %s", "Endpoint(url)", args.url))
        setup.url = args.url
    end

    if (not args.api_key) then
        io.write(string.format("%-30s >> ", "API KEY (leave blank if none)"))
        io.flush()
        setup.api_key = io.read()
    else
        print(string.format("%-30s >> %s", "API KEY (leave blank if none)", args.api_key))
        setup.api_key = args.api_key
    end

    if (not args.model) then
        io.write(string.format("%-30s >> ", "LLM MODEL"))
        io.flush()
        setup.model = io.read()
    else
        print(string.format("%-30s >> %s", "LLM MODEL", args.model))
        setup.model = args.model
    end

    local unnamed_section = uci:add(common.db.uci.cfg, common.db.uci.sect.service)
    uci:set(common.db.uci.cfg, unnamed_section, "name", setup.service)
    uci:set(common.db.uci.cfg, unnamed_section, "url", setup.url)
    uci:set(common.db.uci.cfg, unnamed_section, "api_key", setup.api_key)
    uci:set(common.db.uci.cfg, unnamed_section, "model", setup.model)
    uci:commit(common.db.uci.cfg)
end

local change = function(opt, arg)

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
        print("Service Update!")
    else
        print("Service Not Found...")
    end
end

local show_service_list = function()

    local index = 0

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(tbl)
        index = index + 1
        if tbl.name then
            if index == 1 then
                print("\n\27[1;34m[" .. index .. "] : " .. tbl.name .. " \27[1;32m(in use)\27[0m")
            else
                print("\n\27[1;34m[" .. index .. "] : " .. tbl.name .. "\27[0m")
            end
            print("-----------------------------------------------")
            if tbl.url then
                io.write(string.format("%-8s >> \27[33m%s\27[0m\n", "URL", tbl.url))
                io.flush()
            end

            if tbl.api_key then
                io.write(string.format("%-8s >> \27[33m%s\27[0m\n", "API KEY", tbl.api_key))
                io.flush()
            end

            if tbl.model then
                io.write(string.format("%-8s >> \27[33m%s\27[0m\n", "MODEL", tbl.model))
                io.flush()
            end
        end
    end)
end

local delete = function(arg)

    if not arg.service then
        return
    end

    local target_section = ""

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(service)
        if service.name == arg.service then
            target_section = service[".name"]
        end
    end)

    if #target_section == 0 then
        print("Service Name: " .. arg.service .. " is not found.")
        return
    end


    io.write("Do you delete service [" ..arg.service .. "] (Y/N):")
    io.flush()

    local reply = io.read()

    if reply == 'N' then
        print("canceled.")
    end

    uci:delete(common.db.uci.cfg, target_section)
    uci:commit(common.db.uci.cfg)

    print("Delete service [" .. arg.service .. "]")
end

local select = function(arg)

    if not arg.service then
        return
    end

    local target_section = ""

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function(service)
        if service.name == arg.service then
            target_section = service[".name"]
        end
    end)

    if #target_section == 0 then
        print("Service Name: " .. arg.service .. " is not found.")
        return
    end

    -- swap section data
    uci:reorder(common.db.uci.cfg, target_section, 1)
    uci:commit(common.db.uci.cfg)

    local model = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "model")
    print(arg.service .. " is selected.")
    print("Target model: \27[33m" .. model .. "\27[0m")
end

local chat = function(arg)

    local is_exist = false

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function()
        is_exist = true
    end)

    if not is_exist then
        print("Error!\n\tOne of the service settings exist!")
        print("\tPlease add the service configuration with the add command.")
        return
    end

    local cfg = datactrl.retrieve_ai_service_cfg(arg, common.ai.format.chat)
    local chat = datactrl.load_chat_data(arg, cfg, common.ai.format.chat)
    local your_message

    local service_name = uci:get_first(common.db.uci.cfg, common.db.uci.sect.service, "name", "Unknown")

    print("-----------------------------------")
    print(string.format("%-14s :\27[33m %s \27[0m", "Target Service", service_name))
    print(string.format("%-14s :\27[33m %s \27[0m", "Model", chat.model))
    print("-----------------------------------")

    while true do
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

        local user = {}
        user.role = common.role.user
        user.message = your_message

        push_chat_data_for_record(chat, user)
        record_chat_data(cfg, chat)
        communicate(cfg, chat, common.ai.format.chat)
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
    local cfg = datactrl.retrieve_ai_service_cfg(nil)
    local user_prompt = datactrl.load_chat_data(nil)

    local user = {}
    user.role = common.role.user
    user.message = arg.message

    push_chat_data_for_record(user_prompt, user)
    communicate(cfg, user_prompt, common.ai.format.prompt)
    print()
end

local output = function(arg)

    if (not arg.message) then
        return
    end

    local is_exist = false

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.service, function()
        is_exist = true
    end)

    if not is_exist then
        print("Error!\n\tOne of the service settings exist!")
        print("\tPlease add the service configuration with the add command.")
        return
    end

    local cfg = datactrl.retrieve_ai_service_cfg(arg, common.ai.format.output)
    local all_chat = datactrl.load_chat_data(arg, common.ai.format.output)

    local user = {}
    user.role = common.role.user
    user.message = arg.message

    push_chat_data_for_record(all_chat, user)
    record_chat_data(cfg, all_chat)
    local new_chat_info, message = communicate(cfg, all_chat, common.ai.format.output)
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

local cmd_call = function(arg)

    local cfg = datactrl.retrieve_ai_service_cfg(nil, common.ai.format.call)
    local user_prompt = datactrl.load_chat_data(nil, common.ai.format.call)

    local user = {}
    user.role = common.role.user
    user.message = arg.message

    push_chat_data_for_record(user_prompt, user)
    record_chat_data(cfg, user_prompt)
    communicate(cfg, user_prompt, common.ai.format.call)
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
    cmd_call =  cmd_call,
}
