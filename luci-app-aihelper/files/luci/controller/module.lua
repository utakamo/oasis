-- module.lua
module("luci.controller.luci-app-aihelper.module", package.seeall)

function index()
    entry({"admin", "network", "aihelper"}, firstchild(), "Aihelper", 30).dependent=false
    entry({"admin", "network", "aihelper", "chat"}, template("luci-app-aihelper/chat"), "Chat with AI", 30).dependent=false
    entry({"admin", "network", "aihelper", "setting"}, cbi("luci-app-aihelper/setting"), "Setting", 30).dependent=false
end