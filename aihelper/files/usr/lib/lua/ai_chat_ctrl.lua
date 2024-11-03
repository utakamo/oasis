#!/usr/bin/env lua
local ubus = require("ubus")
local sys = require("luci.sys")
local uci = require("luci.model.uci").cursor()
local jsonc = require("luci.jsonc")
local transfer = require("ai_chat_transfer")
local common = require("aihelper_common")

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

local init = function(arg)

    local basic = {}
    basic.url = uci:get_first("aihelper", "service", "url", "")
    basic.api_key = uci:get_first("aihelper", "service", "api_key", "")

    local chat = {}

    if arg and arg.id then
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
        local request = call("aihelper.title", "auto_set", {id = id})
        local announce =  "\n" .. "\27[1;37;44m" .. "Title:"
        announce = announce  .. "\27[1;33;44m" .. request.title
        announce = announce .. "  \27[1;37;44m" .. "ID:"
        announce = announce .. "\27[1;33;44m" .. id
        announce = announce .. "\27[0m"
        io.write(announce .. "\n")
        io.flush()
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

local communicate = function(basic, chat, format)

    local chat_json = jsonc.stringify(chat, false)
    local ai = {}
    ai.role = "unknown"
    ai.message = ""

    if format == "chat" then
        print("\n" .. chat.model)
    end

    -- markdown ctrl table
    local mark = {}

    local chunk_all = ""

    -- Post
    transfer.post_to_server(basic.url, basic.api_key, chat_json, function(chunk)

        local chunk_json

        chunk_all = chunk_all .. chunk
        chunk_json = jsonc.parse(chunk_all)
        local content = ""

        if not chunk_json then
            return
        end

        chunk_all = ""

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
            content = markdown(mark, chunk_json.message.content)
        end

        if #content > 0 then
            io.write(content)
            io.flush()
        end
    end)

    print()

    if format == "chat" then
        if (ai.role ~= "unknown") and (#ai.message > 0) then
            update_chat(basic, chat, ai)
        end
    end
end

local storage = function(args)

    local storage = {}

    local current_storage_path = uci:get("aihelper", "storage", "path")
    local chat_max = uci:get("aihelper", "storage", "chat_max")

    print("[Current Storage Config]")
    print(string.format("%-30s :%s", "path (Blank if not change)", current_storage_path))
    print(string.format("%-30s :%s\n", "chat-max", chat_max))

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

    if #storage.path > 0 then
        local prefix = uci:get("aihelper", "storage", "prefix")

        if (#current_storage_path == 0) or (#prefix == 0) then
            print("Error! Failed to load configuration information.")
            return
        end

        local result = sys.exec("mv " .. current_storage_path .. "/" .. prefix .. "* " .. storage.path)

        if result ~= "0" then
            print("Error! Failed to move data to new storage location.")
            return
        end

        uci:set("aihelper", "storage", "path", storage.path)
    end

    if #storage.chat_max > 0 then
        uci:set("aihelper", "storage", "chat_max", storage.chat_max)
    end

    uci:commit("aihelper")
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

    local unnamed_section = uci:add("aihelper", "service")
    uci:set("aihelper", unnamed_section, "name", setup.service)
    uci:set("aihelper", unnamed_section, "url", setup.url)
    uci:set("aihelper", unnamed_section, "api_key", setup.api_key)
    uci:set("aihelper", unnamed_section, "model", setup.model)
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

local show_service_list = function()

    local index = 0

    uci:foreach("aihelper", "service", function(tbl)
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

    uci:foreach("aihelper", "service", function(service)
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

    uci:delete("aihelper", target_section)
    uci:commit("aihelper")

    print("Delete service [" .. arg.service .. "]")
end

local select = function(arg)

    if not arg.service then
        return
    end

    local target_section = ""

    uci:foreach("aihelper", "service", function(service)
        if service.name == arg.service then
            target_section = service[".name"]
        end
    end)

    if #target_section == 0 then
        print("Service Name: " .. arg.service .. " is not found.")
        return
    end

    -- swap section data
    uci:reorder("aihelper", target_section, 1)
    uci:commit("aihelper")

    local model = uci:get_first("aihelper", "service", "model")
    print(arg.service .. " is selected.")
    print("Target model: \27[33m" .. model .. "\27[0m")

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

    local basic, chat = init(arg)
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

    local storage_path = uci:get("aihelper", "storage", "path")
    local prefix = uci:get("aihelper", "storage", "prefix")
    local file_path = storage_path .. "/" .. prefix .. arg.id
    os.remove(file_path)

    uci:foreach("aihelper", "chat", function(tbl)
        if tbl.id == arg.id then
            uci:delete("aihelper", tbl[".name"])
        end
    end)

    print("Delete chat data id=" .. arg.id)
end

local prompt = function(arg)

    local basic, prompt = init(nil)

    local user = {}
    user.role = role.user
    user.message = arg.message

    update_chat(basic, prompt, user)
    communicate(basic, prompt, "prompt")
    print()
end

local rename = function(arg)
    local result = call("aihelper.title", "manual_set", {id = arg.id, title = arg.title})

    if result.status == "OK" then
        print("Changed title of chat data with id=" .. arg.id  .. " to " .. result.title .. ".")
    else
        print("Chat data for id=xxxxx could not be found.")
    end
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

local cmd_call = function(arg)

    local basic, prompt = init(nil)

    local user = {}
    user.role = role.user
    user.message = arg.message

    update_chat(basic, prompt, user)
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
    rename = rename,
    list = list,
    cmd_call =  cmd_call,
}
