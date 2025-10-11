# Oasis Local Tool (OLT) Client Server System

Oasis provides the oasis-mod-tool as a plugin module, enabling AI systems to leverage OpenWrt functionality.
The oasis-mod-tool utilizes Lua and ucode scripts that can run as ubus server applications, enabled by OpenWrt’s ubus and rpcd modules.
After installing oasis-mod-tool, you can create Lua or ucode scripts using the syntax rules shown in the examples below. By placing the scripts in the appropriate directory, AI will detect the functionalities defined within them and recognize them as tools.  

<img width="743" height="258" alt="oasis-local-tool(olt)-structure" src="https://github.com/user-attachments/assets/ef70cee2-8618-4c44-8387-c7e9ba469f54" />

> [!IMPORTANT]
> In Oasis local tools, network communication is generally not recommended. 
> This is because, on OpenWrt devices, user scenarios such as AI applications on general-purpose PCs accessing MCP servers like GitHub or Atlassian are not expected. 
> That said, the tools themselves are technically capable of performing network communication.

## Lua OLT Server Example
This section presents an example of managing three tools within the tool group oasis.lua.template.tool.
In Lua, the tool group name corresponds to the script’s filename.
To apply the Lua script, place it in /usr/libexec/rpcd.
```
#!/usr/bin/env lua

local server = require("oasis.local.tool.server")

server.tool("say_hello", {
    tool_desc = "Return a simple greeting. No inputs.",
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
To apply the script, place it in /usr/share/rpcd/ucode.
```
'use strict';

let ubus = require('ubus').connect();
let server = require('oasis.local.tool.server');

server.tool("oasis.ucode.test.tool", "tool_test_I", {
    tool_desc: "This is test I.",
    call: function() {
        return { message: "Execute Test I." };
    }
});

server.tool("oasis.ucode.test.tool", "tool_test_J", {
    tool_desc: "This is test J.",
    exec_msg: "Execute Test J",
    call: function() {
        return { message: "Execute Test J." };
    }
});

server.tool("oasis.ucode.test.tool", "tool_test_K", {
    tool_desc: "This is test K.",
    download_msg: "Downloading Test ...",
    call: function() {
        return { message: "Execute Test K." };
    }
});

server.tool("oasis.ucode.test.tool", "tool_test_L", {
    tool_desc: "This is test L.",
    exec_msg: "Execute Test L",
    download_msg: "Downloading Test ...",
    call: function() {
        return { message: "Execute Test L." };
    }
});

server.tool("oasis.ucode.test.tool", "tool_test_M", {
    tool_desc: "This is test M.",
    call: function() {
        return { message: "Execute Test M.", reboot: true };
    }
});

server.tool("oasis.ucode.test.tool", "tool_test_N", {
    tool_desc: "This is test N.",
    exec_msg: "Execute Test N",
    download_msg: "Downloading Test ...",
    call: function() {
        return { message: "Execute Test N.", reboot: true };
    }
});


server.tool("oasis.ucode.test.tool", "tool_test_O", {
    tool_desc: "This is test O.",
    exec_msg: "Execute Test O",
    download_msg: "Downloading Test ...",
    call: function() {
        return { message: "Execute Test O.", user_only: "This is user only message.", reboot: true };
    }
});

server.tool("oasis.ucode.test.tool", "tool_test_P", {
    tool_desc: "This is test P (restart_service).",
    call: function() {
        return { message: "Execute Test P.", prepare_service_restart: "network" };
    }
});

return server.submit();
```

## How to Apply the Script
To have Oasis recognize the scripts you've created, you’ll need to either reboot OpenWrt or run the command shown below.
```
root@OpenWrt~# service olt_tool restart
root@OpenWrt~# service rpcd restart
```

## Recognition of OLT server scripts
Once scripts such as Lua or ucode are recognized by the Oasis/OpenWrt system, they become visible in the WebUI.
The image below shows an example of how the tools page appears in Oasis.
<img width="947" height="439" alt="image" src="https://github.com/user-attachments/assets/64dc5250-266f-4e4f-b0f6-f89a987b0e90" />
<img width="947" height="439" alt="image" src="https://github.com/user-attachments/assets/3af40cee-db26-4ae3-9621-4d40f966470e" />

## AI tool parameter
| Param name | Desc | Required |
|----------|----------|----------|
| tool_desc    | Tool overview description. The AI uses this information to understand what kind of tool it is. | YES |
| args_desc    | Explanation of tool parameters used by the AI to configure arguments during execution. Not required if the tool does not take any arguments. | NO |
| exec_msg    |  pre-execution message | NO |
| download_msg | download message and effect | NO |

## Tool Response Field
The tool’s response data is provided as a table in Lua or ucode. Certain fields and their values have special meanings or effects.

- `reboot = true`  
If reboot = true exists in the table, the user will be notified to confirm whether to execute a system reboot when the AI’s final response is received.

- `prepare_service_restart = <service>`  
If prepare_service_restart = <service> (e.g. "network") exists in the table, the system will prompt the user for confirmation before proceeding.

- `user_only = <message>`  
As the name suggests, this is the tool execution result that is notified only to the user. It is not sent to the LLM. The tool execution result sent to the AI will have the user_only field removed.  

### Reference (sample)
- Lua  
  https://github.com/utakamo/oasis-tool-box/blob/main/oasis-tool-test/files/usr/libexec/rpcd/oasis.lua.test.tool
- ucode  
  https://github.com/utakamo/oasis-tool-box/blob/main/oasis-tool-test/files/usr/share/rpcd/ucode/oasis.ucode.test.manager.uc
