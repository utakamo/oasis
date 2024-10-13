#!/usr/bin/env lua
local ubus = require("ubus")
local uci = require("luci.model.uci").cursor()
local jsonc = require("luci.jsonc")
local transfer = require("ai_chat_transfer")

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
        local is_code_block = (message:match("```") ~= nil)
        local is_bold_text = (message:match("%*%*") ~= nil)

        if not mark.cnt then
            mark.cnt = {}
            mark.cnt.code_block = 0
            mark.cnt.bold_text = 0
        end

        if is_code_block then
            mark.cnt.code_block = mark.cnt.code_block + 1
        end

        if is_bold_text then
            mark.cnt.bold_text = mark.cnt.bold_text + 1
        end

        -- replace code blocks
        if (mark.cnt.code_block % 2) == 1 then
            message = message:gsub("```", "\27[1;32;47m")
        else
            message = message:gsub("```", "\27[0m")
        end

        if (mark.cnt.bold_text % 2) == 1 then
            message = message:gsub("%*%*", "\27[1;33m")
        else
            message = message:gsub("%*%*", "\27[0m")
        end
    end

    return message
end

local init = function(opt, arg)

    local basic = {}
    basic.url = uci:get_first("aihelper", "service", "url", "")
    basic.api_key = nil

    local chat = {}

    if arg.id then
        basic.id = arg.id
        chat = call("aihelper.chat", "load", {id = basic.id})
    end

    chat.model = uci:get_first("aihelper", "service", "model", "")

    if not chat.messages then
        chat.messages = {}
    end

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

    return basic, chat
end

local update_chat = function(basic, chat, speaker)

    if (not speaker.role) or (not speaker.message) or (#speaker.message == 0) then
        return
    end

    chat.messages[#chat.messages + 1] = {}
    chat.messages[#chat.messages].role = speaker.role
    chat.messages[#chat.messages].content = speaker.message

    -- First Conversation!!
    if #chat.messages == 2 then
        local message = {}
        message.role1 = chat.messages[#chat.messages - 1].role
        message.content1 = chat.messages[#chat.messages - 1].content
        message.role2 = chat.messages[#chat.messages].role
        message.content2 = chat.messages[#chat.messages].content
        local result = call("aihelper.chat", "create", message)
        id = result.id
        local request =call("aihelper.title", "auto_set", {id = id})
        local announce = "\27[1;37;44m" .. "Title:"
        announce = announce  .. "\27[1;33;44m" .. request.title
        announce = announce .. "  \27[1;37;44m" .. "ID:"
        announce = announce .. "\27[1;33;44m" .. id
        announce = announce .. "\27[0m"
        print(announce)
    -- Conversation after the second
    elseif (#chat.messages % 2) == 0 then
        local message = {}
        message.id = id or basic.id
        message.role1 = chat.messages[#chat.messages - 1].role
        message.content1 = chat.messages[#chat.messages - 1].content
        message.role2 = chat.messages[#chat.messages].role
        message.content2 = chat.messages[#chat.messages].content
        call("aihelper.chat", "append", message)
    end
end

local show_chat_history = function(chat)
    local chat_json = jsonc.stringify(chat, false)
    print(chat_json)
end

local communicate = function(basic, chat)

    local chat_json = jsonc.stringify(chat, false)
    local ai = {}
    ai.role = "unknown"
    ai.message = ""

    print("\n" .. chat.model)

    -- markdown ctrl table
    local mark = {}

    -- Post
    transfer.post_to_server(basic.url, chat_json, function(chunk)
        local chunk_json = jsonc.parse(chunk)
        if type(chunk_json) == "table" then
            ai.role = chunk_json.message.role
            ai.message = ai.message .. chunk_json.message.content
            local content = markdown(mark, chunk_json.message.content)
            io.write(content)
        end
    end)

    if (ai.role ~= "unknown") and (#ai.message > 0) then
        update_chat(basic, chat, ai)
    end
end

local storage = function(args)

    local storage = {}

    local storage_path = uci:get("aihelper", "storage", "path")
    local chat_max = uci:get("aihelper", "storage", "chat_max")

    print("[Current Storage Config]")
    print(string.format("%-10s :%s", "path", storage_path))
    print(string.format("%-10s :%s\n", "chat-max", chat_max))

    print("[Setup New Storage Config]")
    print("please input new config!")

    if (not args.path) then
        io.write(string.format("%-10s :", "path"))
        io.flush()
        storage.path = io.read()
    else
        print(string.format("%-10s :%s", "path", args.path))
        storage.path = args.path
    end

    if (not args.chat_max) then
        io.write(string.format("%-10s :", "chat-max"))
        io.flush()
        storage.chat_max = io.read()
    else
        print(string.format("%-10s :%s", "chat-max", args.chat_max))
        storage.chat_max = args.chat_max
    end

    uci:set("aihelper", "storage", "path", storage.path)
    uci:set("aihelper", "storage", "chat_max", storage.chat_max)
    uci:commit("aihelper")
end

local add = function(args)

    local setup = {}

    if (not args.service) then
        io.write(string.format("%-30s :", "Please enter any service name"))
        io.flush()
        setup.service = io.read()
    else
        print(string.format("%-30s :%s", "Please enter any service name", args.service))
        setup.service = args.service
    end

    if (not args.url) then
        io.write(string.format("%-30s :", "URL"))
        io.flush()
        setup.url = io.read()
    else
        print(string.format("%-30s :%s", "URL", args.url))
        setup.url = args.url
    end

    if (not args.api_key) then
        io.write(string.format("%-30s :", "API KEY (leave blank if none)"))
        io.flush()
        setup.api_key = io.read()
    else
        print(string.format("%-30s :%s", "API KEY (leave blank if none)", args.api_key))
        setup.api_key = args.api_key
    end

    if (not args.model) then
        io.write(string.format("%-30s :", "LLM MODEL"))
        io.flush()
        setup.model = io.read()
    else
        print(string.format("%-30s :%s", "LLM MODEL", args.model))
        setup.model = args.model
    end

    local function is_valid_storage_option(option)
        return option == "on" or option == "off"
    end

    if not is_valid_storage_option(args.storage) then
        repeat
            io.write(string.format("%-30s :", "Use internal storage? (on/off)"))
            io.flush()
            args.storage = io.read()
        until is_valid_storage_option(args.storage)
    else
        print(string.format("%-30s :%s", "Use internal storage? (on/off)", args.storage))
    end

    setup.storage = args.storage

    local unnamed_section = uci:add("aihelper", "service")
    uci:set("aihelper", unnamed_section, "name", setup.service)
    uci:set("aihelper", unnamed_section, "url", setup.url)
    uci:set("aihelper", unnamed_section, "api_key", setup.api_key)
    uci:set("aihelper", unnamed_section, "model", setup.model)
    uci:set("aihelper", unnamed_section, "storage", setup.storage)
    uci:commit("aihelper")
end

local change = function(opt, arg)

    local is_update = false

    uci:foreach("aihelper", "service", function(service)
        if service.name == arg.service then
            is_update = true
            if opt.n then
                uci:set("aihelper", service[".name"], "name", opt.n)
            end
            if opt.u then
                uci:set("aihelper", service[".name"], "url", opt.u)
            end
            if opt.k then
                uci:set("aihelper", service[".name"], "api_key", opt.k)
            end
            if opt.m then
                uci:set("aihelper", service[".name"], "model", opt.m)
            end
            if opt.s then
                uci:set("aihelper", service[".name"], "storage", opt.s)
            end
            uci:commit("aihelper")
        end
    end)

    if is_update then
        print("Service Update!")
    else
        print("Service Not Found...")
    end
end

local select = function(arg)

    if not arg.service then
        return
    end

    local unnamed_section_idx = 0

    local top_unnamed_section
    local top_service = {}

    local swap_target_section
    local swap_target_service = {}

    uci:foreach("aihelper", "service", function(service)

        if unnamed_section_idx == 0 then
            top_unnamed_section = service[".name"]
            top_service.name = service.name
            top_service.url = service.url
            top_service.api_key = service.api_key
            top_service.model = service.model
            top_service.storage = service.storage
        end

        if (service.name == arg.service) then
            swap_target_section = service[".name"]
            swap_target_service.name = service.name
            swap_target_service.url = service.url
            swap_target_service.api_key = service.api_key
            swap_target_service.model = service.model
            swap_target_service.storage = service.storage
        end

        unnamed_section_idx = unnamed_section_idx + 1
    end)

    -- swap section data
    uci:tset("aihelper", top_unnamed_section, {
        name = swap_target_service.name,
        url = swap_target_service.url,
        api_key = swap_target_service.api_key,
        model = swap_target_service.model,
        storage = swap_target_service.storage,
    })

    uci:tset("aihelper", swap_target_section, {
        name = top_service.name,
        url = top_service.url,
        api_key = top_service.api_key,
        model = top_service.model,
        storage = top_service.storage,
    })

    uci:commit("aihelper")
end

local chat = function(opt, arg)

    local is_exist = false

    uci:foreach("aihelper", "service", function()
        is_exist = true
    end)

    if not is_exist then
        print("Error!\n\tOne of the service settings exist!")
        print("\tPlease add the service configuration with the add command.")
        return
    end

    local basic, chat = init(opt, arg)
    local your_message

    while true do
        repeat
            io.write("You :")
            io.flush()
            your_message = io.read()

            if not your_message then
                return
            end

            if your_message == "show" then
                show_chat_history(chat)
            end

        until (#your_message > 0) and (your_message ~= "show")

        if your_message == "exit" then
            print("The chat is over.")
            break;
        end

        local user = {}
        user.role = role.user
        user.message = your_message

        update_chat(basic, chat, user)
        communicate(basic, chat)

        print()
    end
end

local prompt = function()

    local your_message

    io.write("You :")
    io.flush()
    your_message = io.read()

    local prompt = {}
    prompt.role = role.user
    prompt.message = your_message
end

local list = function()

    local list = call("aihelper.chat", "list", {})

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
    select = select,
    chat = chat,
    prompt = prompt,
    list = list,
}