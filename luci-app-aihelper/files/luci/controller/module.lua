-- module.lua
module("luci.controller.luci-app-aihelper.module", package.seeall)

function index()
    entry({"admin", "network", "aihelper"}, firstchild(), "Aihelper", 30).dependent=false
    entry({"admin", "network", "aihelper", "network"}, cbi("aihelper/chat"), "Chat with AI", 30).dependent=false
    entry({"admin", "network", "aihelper", "network"}, cbi("aihelper/setting"), "AI Setting", 30).dependent=false
end