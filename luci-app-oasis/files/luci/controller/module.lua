local util = require("luci.util")
local luci_http = require("luci.http")
local jsonc = require("luci.jsonc")
local oasis = require("oasis.chat.apply")

module("luci.controller.luci-app-oasis.module", package.seeall)

function index()
    entry({"admin", "network", "oasis"}, firstchild(), "Oasis", 30).dependent=false
    entry({"admin", "network", "oasis", "setting"}, cbi("luci-app-oasis/setting"), "Setting", 30).dependent=false
    entry({"admin", "network", "oasis", "chat"}, template("luci-app-oasis/chat"), "Chat with AI", 30).dependent=false
    entry({"admin", "network", "oasis", "chat-list"}, call("retrive_chat_list"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-chat-data"}, call("load_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "export-chat-data"}, call("load_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "delete-chat-data"}, call("delete_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "rename-chat"}, call("rename"), nil).leaf = true
    entry({"admin", "network", "oasis", "apply-uci-cmd"}, call("apply_uci_cmd"), nil).leaf = true
    entry({"admin", "network", "oasis", "confirm"}, call("confirm"), nil).leaf = true
end

function retrive_chat_list()
    -- ubus call
    local result = util.ubus("oasis.chat", "list", {})

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function load_chat_data()

    local params = luci_http.formvalue("params")

    if not params then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    -- Create a parameter table for ubus call
    local json_param = { id = params }

    local result = util.ubus("oasis.chat", "load", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function delete_chat_data()

    local params = luci_http.formvalue("params")

    if not params then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    -- Create a parameter table for ubus call
    local json_param = { id = params }

    local result = util.ubus("oasis.chat", "delete", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function rename()

    local id = luci_http.formvalue("id")
    local title = luci_http.formvalue("title")

    if (not id) or (not title) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local json_param = {id = id, title = title}

    local result = util.ubus("oasis.title", "manual_set", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function apply_uci_cmd()

    local uci_list_json = luci_http.formvalue("uci_list")
    local chat_id = luci_http.formvalue("id")

    if (not uci_list_json) or (not chat_id) then
        -- for debug
        os.execute("echo \"apply_uci_cmd argument error\" >> /tmp/oasis-apply.log")
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    -- for debug
    os.execute("echo \"chat_id = " .. chat_id .. "\" >> /tmp/oasis-apply.log")
    os.execute("echo \"uci_list_json" .. uci_list_json .. "\" >> /tmp/oasis-apply.log")

    local uci_list = jsonc.parse(uci_list_json)

    oasis.apply(uci_list, chat_id)

    luci_http.prepare_content("application/json")
    luci_http.write_json("OK")
end

function confirm()
    local answer = luci_http.formvalue("answer")

    if not answer then
        os.execute("echo \"confirm error\" >> /tmp/oasis-confirm.log")
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local result = oasis.confirm(answer)

    luci_http.prepare_content("application/json")
    luci_http.write_json("OK")
end