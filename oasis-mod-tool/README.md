# Oasis Local Tool (OLT) Client Server System

Oasis provides the oasis-mod-tool as a plugin module, enabling AI systems to leverage OpenWrt functionality.
The oasis-mod-tool utilizes Lua and ucode scripts that can run as ubus server applications, enabled by OpenWrt’s ubus and rpcd modules.
After installing oasis-mod-tool, you can create Lua or ucode scripts using the syntax rules shown in the examples below. By placing the scripts in the appropriate directory, AI will detect the functionalities defined within them and recognize them as tools.  

<img width="789" height="254" alt="Image" src="https://github.com/user-attachments/assets/a5f616a4-d899-459f-814a-a915796f1aa8" />

## Lua OLT Server Example
This section presents an example of managing three tools within the tool group oasis.lua.template.tool.server.
In Lua, the tool group name corresponds to the script’s filename.
To apply the Lua script, place it in /usr/libexec/rpcd.
```
#!/usr/bin/env lua

local server = require("oasis.local.tool.server")

server.tool("get_hello", {
    tool_desc = "Return a fixed greeting message.",
    call = function()
        local res = server.response({ message = "Hello, world!" })
        return res
    end
})

server.tool("get_weather", {
    -- args_desc: Description of parameters specified when invoking the tool.
    args_desc   = { "City and country e.g. Bogotá, Colombia" },
    args        = { location = "a_string" },

    -- tool_desc: Description of the tool's functionality.
    tool_desc   = "Get current temperature for a given location.",
    call = function(args)
        -- Mock: Returns a fake temperature for the given location
        local res = server.response({ location = args.location, temperature = "25°C", condition = "Sunny" })
        return res
    end
})

server.tool("add_numbers", {

    tool_desc   = "Add two numbers together and return the result.",

    args_desc   = { "First number", "Second number" },
    args        = { num1 = "a_string", num2 = "a_string" },

    call = function(args)
        local a = tonumber(args.num1) or 0
        local b = tonumber(args.num2) or 0
        local res = server.response({ num1 = a, num2 = b, sum = a + b })
        return res
    end
})

server.run(arg)
```

## ucode OLT Server Example
This section explains how to write a script that manages tools named oasis.ucode.local.tool.server1 and oasis.ucode.local.tool.server2.
Unlike Lua, ucode does not use the script’s filename as the tool group name—instead, the tool group must be explicitly declared when defining each tool.
To apply the script, place it in /usr/rpcd/ucode.
```
'use strict';

let ubus = require('ubus').connect();
let server = require('oasis.local.tool.server');

server.tool("oasis.ucode.template.tool1", "get_goodbye", {
    tool_desc: "Return a fixed goodbye message.",
    call: function() {
        return { message: "Goodbye! This is a template tool." };
    }
});

server.tool("oasis.ucode.template.tool1", "subtract", {
    tool_desc: "Subtract the second number from the first and return the result.",
    args_desc: [
        "First number (integer)",
        "Second number (integer)"
    ],
    args: {
        num1: 0,
        num2: 0
    },
    call: function(request) {
        let a = request.args.num1;
        let b = request.args.num2;
        return { num1: a, num2: b, difference: a - b };
    }
});

server.tool("oasis.ucode.template.tool2", "concat_strings", {
    tool_desc: "Concatenate two strings and return the result.",
    args_desc: [
        "First string",
        "Second string"
    ],
    args: {
        str1: "",
        str2: ""
    },
    call: function(request) {
        return { str1: request.args.str1, str2: request.args.str2, result: request.args.str1 + request.args.str2 };
    }
});

return server.submit();
```

## How to Apply the Script
To have Oasis recognize the scripts you've created, you’ll need to either reboot OpenWrt or run the command shown below.
```
root@OpenWrt~# /etc/init.d/olt_tool restart
root@OpenWrt~# service rpcd restart
```
> [!NOTE]
> If your script includes multiple module imports or similar operations, it may take a few minutes (typically 1 to 3) before it’s recognized by the Oasis/OpenWrt system.

## Recognition of OLT server scripts
Once scripts such as Lua or ucode are recognized by the Oasis/OpenWrt system, they become visible in the WebUI.
The image below shows an example of how the tools page appears in Oasis.
<img width="947" height="439" alt="image" src="https://github.com/user-attachments/assets/64dc5250-266f-4e4f-b0f6-f89a987b0e90" />
<img width="947" height="439" alt="image" src="https://github.com/user-attachments/assets/3af40cee-db26-4ae3-9621-4d40f966470e" />

