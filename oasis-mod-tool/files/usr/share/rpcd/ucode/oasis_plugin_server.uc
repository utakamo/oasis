'use strict';

/*
# Oasis Local Tool (OLT) Server (uCode Script Ver)
 This server script is based on concepts inspired by the Model Context Protocol and Agents.json.
 By leveraging UBUS, an integral part of the OpenWrt ecosystem, the client and server can cooperate
 to allow the AI to access the tools it provides.
 On OpenWrt systems with Oasis and oasis-mod-tool installed, third-party developers can easily expose
 tools to the AI by simply downloading server scripts.

 uCode scripts load faster than Lua scripts.

 About rpcd ucode plugin:
 https://lxr.openwrt.org/source/rpcd/examples/ucode/example-plugin.uc
*/

let ubus = require('ubus').connect();
let server = require('oasis.local.tool.server');

server.tool("oasis.ucode.tool.server1", "method_1", {
    tool_desc: "This is test tool No.1",
    call: function() {
        return { response: "oasis.ucode.tool.server1 --- No.1"};
    }
});

server.tool("oasis.ucode.tool.server1", "method_2", {
    tool_desc: "This is test tool No.2",

    args_desc: [
        "sample Integer parameter.",
        "sample boolean parameter.",
        "sample string parameter.",
    ],

    args: {
        foo: 32,
        baz: true,
        qrx: "example"
    },

    call: function() {
        return {
            got_args: request.args,
            got_info: request.info
        };
    }
});

server.tool("oasis.ucode.tool.server2", "method_3", {
    tool_desc: "This is test tool No.1",
    call: function() {
        return { response: "oasis.ucode.tool.server2 --- No.1"};
    }
});

server.tool("oasis.ucode.tool.server2", "method_4", {
    tool_desc: "This is test tool No.2",
    call: function() {
        return { response: "oasis.ucode.tool.server2 --- No.2"};
    }
});

return server.submit();