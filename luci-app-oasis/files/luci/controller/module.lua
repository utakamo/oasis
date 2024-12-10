-- module.lua
module("luci.controller.luci-app-oasis.module", package.seeall)

function index()
    entry({"admin", "network", "oasis"}, firstchild(), "Oasis", 30).dependent=false
    entry({"admin", "network", "oasis", "chat"}, template("luci-app-oasis/chat"), "Chat with AI", 30).dependent=false
    entry({"admin", "network", "oasis", "setting"}, cbi("luci-app-oasis/setting"), "Setting", 30).dependent=false
end