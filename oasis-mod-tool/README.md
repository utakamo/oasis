# Oasis Local Tool (OLT) Server System
> [!IMPORTANT]
> >
> As of July 2025, the oasis-mod-tool cannot run properly. Therefore, you'll need to wait for its official release before using it.

Oasis provides the oasis-mod-tool as a plugin module, enabling AI systems to leverage OpenWrt functionality.
The oasis-mod-tool utilizes Lua and uCode scripts that can run as ubus server applications, enabled by OpenWrt’s ubus and rpcd modules.
After installing oasis-mod-tool, you can create Lua or uCode scripts using the syntax rules shown in the examples below. By placing the scripts in the appropriate directory, AI will detect the functionalities defined within them and recognize them as tools.  

## Lua Script Sample
Script location: /usr/libexec/rpcd  
```
#!/usr/bin/env lua

local server = require("oasis.local.tool.server")

-- Sample tool "get_weather"
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

server.tool("get_wlan_ifname_list", {
    -- tool_desc: Description of the tool's functionality.
    tool_desc = "Get the list of WLAN interface names.",
    call = function()
        -- Mock: Returns a fake temperature for the given location
        local res = server.response({ ifname1 = "wlan0", ifname2 = "wlan1" })
        return res
    end
})

server.tool("echo", {
    -- args_desc: Description of parameters specified when invoking the tool.
    args_desc = { "Parameter 1 (string)", "Parameter 2 (string)" },
    args = { param1 = "a_string", param2 = "a_string" },

    -- tool_desc: Description of the tool's functionality.
    tool_desc = "Echoes back the received parameters.",
    call = function(args)
        -- Mock: Returns the received parameters as is
        local res = server.response({
            received_param1 = args.param1,
            received_param2 = args.param2
        })
        return res
    end
})

server.run(arg)
```

## uCode Script Sample
```

```

## How to Apply the Script
To have Oasis recognize the scripts you've created, you’ll need to either reboot OpenWrt or run the command shown below.
```
root@OpenWrt~# /etc/init.d/olt_tool restart
root@OpenWrt~# service rpcd restart
```
> [!NOTE]
> If your script includes multiple module imports or similar operations, it may take a few minutes (typically 1 to 3) before it’s recognized by the Oasis/OpenWrt system.
