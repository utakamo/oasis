'use strict';

/*
# Oasis Local Tool (OLT) Server (ucode Script Ver)
 This server script is based on concepts inspired by the Model Context Protocol and Agents.json.
 By leveraging UBUS, an integral part of the OpenWrt ecosystem, the client and server can cooperate
 to allow the AI to access the tools it provides.
 On OpenWrt systems with Oasis and oasis-mod-tool installed, third-party developers can easily expose
 tools to the AI by simply downloading server scripts.

 ucode scripts load faster than Lua scripts.

 About rpcd ucode plugin:
 https://lxr.openwrt.org/source/rpcd/examples/ucode/example-plugin.uc
*/

let server = require('oasis.local.tool.server');

server.tool("oasis.hw.status", "get_board_info", {
    tool_desc: "Get this device board information.",
    call: function() {
        const fs = require('fs');
        const file = fs.open('/etc/board.json', 'r');
        const output = file.read("all");
        file.close();
        let board_info_tbl = json(output);
        return { result : board_info_tbl };
    }
});

return server.submit();
