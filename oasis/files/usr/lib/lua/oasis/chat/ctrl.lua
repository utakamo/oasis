#!/usr/bin/env lua
local ubus = require("ubus")
local sys = require("luci.sys")
local uci = require("luci.model.uci").cursor()
local jsonc = require("luci.jsonc")
local transfer = require("oasis.chat.transfer")
local common = require("oasis.common")
local filter = require("oasis.chat.filter")

local role = {
    system = "system",
    user = "user",
    assistant = "assistant"
}

local id

local call = function(object, method, json_param)

    local conn = ubus.connect()

    if not conn then
        return
    end

    local result = conn:call(object, method, json_param)

    return result
end

local function markdown(mark, message)

    if not mark then
        message = message:gsub("```", "\27[1;32;47m")
        message = message:gsub("\27%[1;32;47m(.-)\27%[1;32;47m", "\27[1;32;47m%1\27[0m")
        message = message:gsub("%*%*", "\27[1;33m")
        message = message:gsub("\27%[1;33m(.-)\27%[1;33m", "\27[1;33m%1\27[0m")
    else
        if not mark.cnt then
            mark.cnt = {}
            mark.cnt.code_block = 0
            mark.cnt.bold_text = 0
        end

        while true do
            local is_code_block = (message:match("```") ~= nil)

            if not is_code_block then
                break
            end

            mark.cnt.code_block = mark.cnt.code_block + 1

            -- replace code blocks
            if (mark.cnt.code_block % 2) == 1 then
                message = message:gsub("```", "\27[1;32;47m", 1)
            else
                message = message:gsub("```", "\27[0m", 1)
            end
        end

        while true do
            local is_bold_text = (message:match("%*%*") ~= nil)

            if not is_bold_text then
                break
            end

            mark.cnt.bold_text = mark.cnt.bold_text + 1

            -- replace bold blocks
            if (mark.cnt.bold_text % 2) == 1 then
                message = message:gsub("%*%*", "\27[1;33m")
            else
                message = message:gsub("%*%*", "\27[0m")
            end
        end
    end

    return message
end

local init = function(arg, format)

    local basic = {}
    basic.url = uci:get_first("oasis", "service", "url", "")
    basic.api_key = uci:get_first("oasis", "service", "api_key", "")

    local chat = {}

    if arg and arg.id and (#arg.id ~= 0) then
        basic.id = arg.id
        chat = call("oasis.chat", "load", {id = basic.id})
    end

    chat.model = uci:get_first("oasis", "service", "model", "")

    if not chat.messages then
        chat.messages = {}
    end

    -- TODO: Separate the init function into load_service and load_chat_history and print.
    if format ~= "output" then
        for _, tbl in ipairs(chat.messages) do
            if tbl.role == role.user then
                print("You :" .. tbl.content)
            elseif tbl.role == role.assistant then

                local content = markdown(nil, tbl.content)

                print()
                print(chat.model)
                print(content)
            end
        end
    end

    if format == "output" then
        if (arg.sysmsg_key and (#arg.sysmsg_key > 0)) then
            basic.sysmsg_key = arg.sysmsg_key
            -- os.execute("echo " .. basic.sysmsg_key .. " >> /tmp/sysmsg.log")
        end
    end

    return basic, chat
end

local push_chat_data_for_record = function(chat, speaker)

    if (not speaker.role) or (not speaker.message) or (#speaker.message == 0) then
        return
    end

    chat.messages[#chat.messages + 1] = {}
    chat.messages[#chat.messages].role = speaker.role
    chat.messages[#chat.messages].content = speaker.message
end

local create_chat_file = function(service, chat)
    -- TODO:
    -- Update to allow chat files to be created even when role:system is not present.
    local message = {}
    if (service.sysmsg_key) and (#service.sysmsg_key > 0) and (service.sysmsg_key == "casual") then
        os.execute("echo \"no system message\" >> /tmp/oasis-create-chat-file.log")
        message.role1 = chat.messages[#chat.messages - 1].role
        message.content1 = chat.messages[#chat.messages - 1].content
        message.role2 = chat.messages[#chat.messages].role
        message.content2 = chat.messages[#chat.messages].content
        message.role3 = ""
        message.content3 = ""
    else
        os.execute("echo \"system message\" >> /tmp/oasis-create-chat-file.log")
        message.role1 = chat.messages[#chat.messages - 2].role
        message.content1 = chat.messages[#chat.messages - 2].content
        message.role2 = chat.messages[#chat.messages - 1].role
        message.content2 = chat.messages[#chat.messages - 1].content
        message.role3 = chat.messages[#chat.messages].role
        message.content3 = chat.messages[#chat.messages].content
    end

    local result = call("oasis.chat", "create", message)
    service.id = result.id
    return result.id
end

local set_chat_title = function(chat_id)
    local request = call("oasis.title", "auto_set", {id = chat_id})
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
    message.id = id or service.id
    message.role1 = chat.messages[#chat.messages - 1].role
    message.content1 = chat.messages[#chat.messages - 1].content
    message.role2 = chat.messages[#chat.messages].role
    message.content2 = chat.messages[#chat.messages].content
    call("oasis.chat", "append", message)
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

local communicate = function(basic, chat, format)

    local ai = {}
    ai.role = "unknown"
    ai.message = ""

    local spath = uci:get("oasis", "role", "path")
    local sysrole = common.load_conf_file(spath)

    -- chat ..... chat mode for cui
    if (format == "chat") and ((not basic.id) or (#basic.id == 0)) then
        table.insert(chat.messages, 1, {
            role = role.system,
            content = sysrole.default.chat
        })
    -- output ... chat mode for luci
    elseif (format == "output") and ((not basic.id) or (#basic.id == 0)) then
        if (basic.sysmsg_key) and (#basic.sysmsg_key > 0) and (basic.sysmsg_key ~= "casual") then
            table.insert(chat.messages, 1, {
                role = role.system,
                content = sysrole[basic.sysmsg_key].chat
            })
        end
    -- prompt ... prompt mode for cui
    elseif format == "prompt" then
        table.insert(chat.messages, 1, {
            role = role.system,
            content = sysrole.default.prompt
        })
    -- call ... script call mode for cui
    elseif format == "call" then
        table.insert(chat.messages, 1, {
            role = role.system,
            content = sysrole.default.call
        })
    end

    if format == "chat" then
        print("\n\27[34m" .. chat.model .. "\27[0m")
    end

    local chat_json = jsonc.stringify(chat, false)

    -- markdown ctrl table
    local mark = {}

    local chunk_all = ""

    -- Post
    transfer.post_to_server(basic.url, basic.api_key, chat_json, function(chunk)

        local chunk_json

        -- [OpenAI Case]
        chunk_all = chunk_all .. chunk
        chunk_json = jsonc.parse(chunk_all)
        local plain_text = ""

        if not chunk_json then
            return
        end

        if (chunk_json) and (type(chunk_json) == "table") then

            -- for ChatGPT
            -- A choices array exists in the response data of chatgpt.
            if chunk_json.choices then
                chunk_json.message = {}
                chunk_json.message.role =  chunk_json.choices[1].message.role
                chunk_json.message.content = chunk_json.choices[1].message.content
            end

            ai.role = chunk_json.message.role
            ai.message = ai.message .. chunk_json.message.content
            plain_text = markdown(mark, chunk_json.message.content)
        end

        if #plain_text > 0 then
            local message = ""

            if (format == "chat") or (format == "prompt") or (format == "call") then
                message = plain_text
            elseif format == "output" then

                -- for ChatGPT
                -- A choices array exists in the response data of chatgpt.
                if chunk_json.choices then
                    chunk_all = jsonc.stringify(chunk_json, false)
                end

                message = chunk_all
            end

            io.write(message)
            io.flush()
        end

        chunk_all = ""
    end)

    local new_chat_info = nil

    if format == "chat" then
        -- print("#ai.message = " .. #ai.message)
        -- print("ai.message = " .. ai.message)
        if (ai.role ~= "unknown") and (#ai.message > 0) then
            push_chat_data_for_record(chat, ai)
            record_chat_data(basic, chat)
        end
    elseif format == "output" then
        if (ai.role ~= "unknown") and (#ai.message > 0) then

            -- debug start
            --[[
            os.execute("echo " .. basic.id .. " >> /tmp/oasis-id1.log")
            os.execute("echo #basic.id = " .. #basic.id .. " >> /tmp/oasis.log")
            os.execute("echo \"ai.message = " .. ai.message .. "\" >> /tmp/oasis-ai.log")

            if (not basic.id) then
                os.execute("echo not basic.id >> /tmp/oasis.log")
            else
                os.execute("echo basic.id exist >> /tmp/oasis.log")
            end
            ]]
            -- debug end

            if (not basic.id) or (#basic.id == 0) then
                os.execute("echo \"basic.id == 0\" >> /tmp/oasis-id2.log")
                push_chat_data_for_record(chat, ai)
                local chat_info = {}
                chat_info.id = create_chat_file(basic, chat)
                local result = call("oasis.title", "auto_set", {id = chat_info.id})
                chat_info.title = result.title
                new_chat_info = jsonc.stringify(chat_info, false)
            else
                os.execute("echo " .. basic.id  .. " >> /tmp/oasis-id3.log")
                push_chat_data_for_record(chat, ai)
                append_chat_data(basic, chat)
            end
        end
    end

    return new_chat_info, ai.message
end

local storage = function(args)

    local storage = {}

    local current_storage_path = uci:get("oasis", "storage", "path")
    local chat_max = uci:get("oasis", "storage", "chat_max")

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
        local prefix = uci:get("oasis", "storage", "prefix")

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

        uci:set("oasis", "storage", "path", storage.path)
    end

    if #storage.chat_max > 0 then
        uci:set("oasis", "storage", "chat_max", storage.chat_max)
    end

    uci:commit("oasis")
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

    local unnamed_section = uci:add("oasis", "service")
    uci:set("oasis", unnamed_section, "name", setup.service)
    uci:set("oasis", unnamed_section, "url", setup.url)
    uci:set("oasis", unnamed_section, "api_key", setup.api_key)
    uci:set("oasis", unnamed_section, "model", setup.model)
    uci:commit("oasis")
end

local change = function(opt, arg)

    local is_update = false

    uci:foreach("oasis", "service", function(service)
        if service.name == arg.service then
            is_update = true
            if opt.n then
                uci:set("oasis", service[".name"], "name", opt.n)
            end
            if opt.u then
                uci:set("oasis", service[".name"], "url", opt.u)
            end
            if opt.k then
                uci:set("oasis", service[".name"], "api_key", opt.k)
            end
            if opt.m then
                uci:set("oasis", service[".name"], "model", opt.m)
            end
            if opt.s then
                uci:set("oasis", service[".name"], "storage", opt.s)
            end
            uci:commit("oasis")
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

    uci:foreach("oasis", "service", function(tbl)
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

    uci:foreach("oasis", "service", function(service)
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

    uci:delete("oasis", target_section)
    uci:commit("oasis")

    print("Delete service [" .. arg.service .. "]")
end

local select = function(arg)

    if not arg.service then
        return
    end

    local target_section = ""

    uci:foreach("oasis", "service", function(service)
        if service.name == arg.service then
            target_section = service[".name"]
        end
    end)

    if #target_section == 0 then
        print("Service Name: " .. arg.service .. " is not found.")
        return
    end

    -- swap section data
    uci:reorder("oasis", target_section, 1)
    uci:commit("oasis")

    local model = uci:get_first("oasis", "service", "model")
    print(arg.service .. " is selected.")
    print("Target model: \27[33m" .. model .. "\27[0m")

end

local chat = function(opt, arg)

    local is_exist = false

    uci:foreach("oasis", "service", function()
        is_exist = true
    end)

    if not is_exist then
        print("Error!\n\tOne of the service settings exist!")
        print("\tPlease add the service configuration with the add command.")
        return
    end

    local basic, chat = init(arg, "chat")
    local your_message

    local service_name = uci:get_first("oasis", "service", "name", "Unknown")

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
        user.role = role.user
        user.message = your_message

        push_chat_data_for_record(chat, user)
        record_chat_data(basic, chat)
        communicate(basic, chat, "chat")
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

    local storage_path = uci:get("oasis", "storage", "path")
    local prefix = uci:get("oasis", "storage", "prefix")
    local file_path = storage_path .. "/" .. prefix .. arg.id
    os.remove(file_path)

    uci:foreach("oasis", "chat", function(tbl)
        if tbl.id == arg.id then
            uci:delete("oasis", tbl[".name"])
        end
    end)

    print("Delete chat data id=" .. arg.id)
end

local prompt = function(arg)
    local basic, prompt = init(nil)

    local user = {}
    user.role = role.user
    user.message = arg.message

    push_chat_data_for_record(prompt, user)
    communicate(basic, prompt, "prompt")
    print()
end

local output = function(arg)

    if (not arg.message) then
        return
    end

    local is_exist = false

    uci:foreach("oasis", "service", function()
        is_exist = true
    end)

    if not is_exist then
        print("Error!\n\tOne of the service settings exist!")
        print("\tPlease add the service configuration with the add command.")
        return
    end

    local basic, chat = init(arg, "output")

    local user = {}
    user.role = role.user
    user.message = arg.message

    push_chat_data_for_record(chat, user)
    record_chat_data(basic, chat)
    local new_chat_info, message = communicate(basic, chat, "output")
    return new_chat_info, message
end

local rename = function(arg)
    local result = call("oasis.title", "manual_set", {id = arg.id, title = arg.title})

    if result.status == "OK" then
        print("Changed title of chat data with id=" .. arg.id  .. " to " .. result.title .. ".")
    else
        print("Chat data for id=" .. arg.id .. " could not be found.")
    end
end

local list = function()

    local list = call("oasis.chat", "list", {})

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

    local basic, prompt = init(nil, "call")

    local user = {}
    user.role = role.user
    user.message = arg.message

    push_chat_data_for_record(prompt, user)
    record_chat_data(basic, prompt)
    communicate(basic, prompt, "call")
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
