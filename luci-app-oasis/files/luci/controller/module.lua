-- module.lua
module("luci.controller.luci-app-oasis.module", package.seeall)

function index()
    entry({"admin", "network", "oasis"}, firstchild(), "Oasis", 30).dependent=false
    entry({"admin", "network", "oasis", "setting"}, cbi("luci-app-oasis/setting"), "Setting", 30).dependent=false
    entry({"admin", "network", "oasis", "chat"}, template("luci-app-oasis/chat"), "Chat with AI", 30).dependent=false
    entry({"admin", "network", "oasis", "chat-list"}, call("retrive_chat_list"), nil).leaf = true
end

function retrive_chat_list()
    local util = require("luci.util")
    local luci_http = require("luci.http")

    -- ubus call
    local result = util.ubus("oasis.chat", "list", {})

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end
