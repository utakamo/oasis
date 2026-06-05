# Oasis Local Tool (OLT) Client Server System

Oasis provides the oasis-mod-tool as a plugin module, enabling AI systems to leverage OpenWrt functionality.
The oasis-mod-tool utilizes Lua and ucode scripts that can run as ubus server applications, enabled by OpenWrt’s ubus and rpcd modules.
After installing oasis-mod-tool, you can create Lua or ucode scripts using the syntax rules shown in the examples below. These scripts implement the actual ubus methods, while Manifest files describe those methods as AI tools.

<img width="743" height="258" alt="oasis-local-tool(olt)-structure" src="https://github.com/user-attachments/assets/ef70cee2-8618-4c44-8387-c7e9ba469f54" />

> [!IMPORTANT]
> In Oasis local tools, network communication is generally not recommended. 
> This is because, on OpenWrt devices, user scenarios such as AI applications on general-purpose PCs accessing MCP servers like GitHub or Atlassian are not expected. 
> That said, the tools themselves are technically capable of performing network communication.

## Manifest-based Tool Management
oasis-mod-tool uses Manifest files as the main source of local tool definitions.

A Manifest describes the AI-facing metadata for each tool:

- which ubus server provides the tool
- the tool name
- the tool description shown to the AI
- input parameters, required fields, and whether additional properties are allowed
- optional execution and download messages
- optional timeout metadata

Manifest files are stored under:

```
/etc/oasis/tool-manifest.d/
```

Manifest files can be generated from AI tool ubus server scripts written for Oasis. Use the `oasis manifest` command to inspect candidate scripts and generate Manifest JSON from those scripts.

The generator targets Oasis-managed tool server scripts that use `oasis.local.tool.server`. If you want to expose an existing ubus method, such as a standard OpenWrt ubus API, write a `manual` Manifest instead of generating one from a script.

Package-provided Manifest files are installed into this directory. During installation, oasis-mod-tool applies its bundled Manifest files automatically. The Tools page refresh action and `oasis_tool_setup refresh` rebuild the Oasis UCI `tool` sections from Manifest definitions.

When creating an Oasis AI tool package, it is recommended to generate the corresponding Manifest from the AI tool ubus server script in advance by running the `oasis manifest` command, then include that Manifest file in the package. This allows the package to install both the tool implementation and the AI-facing tool definition together.

Additional tool packages should install their Manifest files under `/etc/oasis/tool-manifest.d/` and either apply them during package installation or instruct users to run `oasis_tool_setup refresh`.

For example, a package installation script can apply a Manifest non-interactively:

```
oasis manifest apply --yes /etc/oasis/tool-manifest.d/lua.<tool-server>.json
```

A typical package layout is:

```
files/usr/libexec/rpcd/<tool-server>
files/etc/oasis/tool-manifest.d/lua.<tool-server>.json
```

For ucode tools, place the script under `files/usr/share/rpcd/ucode/` and use a Manifest such as:

```
files/usr/share/rpcd/ucode/<tool-server>.uc
files/etc/oasis/tool-manifest.d/ucode.<tool-server>.json
```

In the current model, the relationship is:

- rpcd Lua/ucode scripts implement the actual OpenWrt-side tool behavior.
- Manifest files describe those scripts, or other ubus methods, as AI tools.
- UCI `tool` sections are the runtime registry generated from Manifest files.
- Enabled UCI tool entries are converted into Function Calling schemas when local tools and Function Calling are enabled for the selected AI service.

This means Manifest files are the preferred way to describe and manage tools. The generated UCI entries are runtime state and should usually be managed through Oasis rather than edited by hand. Tool enable/disable state is not stored in the Manifest; it is stored in the generated UCI `tool` sections.

### Manifest Source Types
Manifest files support these source types:

| source_type | Purpose |
|----------|----------|
| `lua_script` | Tool definitions generated from an Oasis Lua rpcd script. |
| `ucode_script` | Tool definitions generated from an Oasis ucode rpcd script. |
| `manual` | Hand-written tool definitions for an existing ubus server or standard OpenWrt functionality. |

`manual` Manifests are useful when a tool does not need a new Oasis-specific script. For example, an existing OpenWrt ubus method can be exposed to the AI by writing a Manifest that describes the method and its parameters.

Manual Manifests may require user confirmation from the Tools page before Oasis applies them to the runtime UCI tool registry.

### Manifest Example
The following is a minimal Manifest structure:

```json
{
  "version": 1,
  "source_type": "manual",
  "source_path": "",
  "tools": [
    {
      "server": "system",
      "name": "board",
      "type": "function",
      "description": "Get this device board information.",
      "execution_message": "",
      "download_message": "",
      "timeout": "",
      "required": [],
      "properties": [],
      "additional_properties": false
    }
  ]
}
```

For generated Manifests, `source_type` is normally `lua_script` or `ucode_script`, and `source_path` points to the rpcd script that implements the tool. The script referenced by `source_path` must exist on the target system. Lua rpcd scripts should also be executable.

### Manifest Commands
The `oasis manifest` command is available when oasis-mod-tool is installed.

```
oasis manifest
oasis manifest build <script_path>
oasis manifest apply <manifest_path>
oasis manifest apply --yes <manifest_path>
```

- `oasis manifest` lists candidate scripts and their expected Manifest paths.
- `oasis manifest build <script_path>` reads an AI tool ubus server script and prints the generated Manifest JSON to standard output.
- `oasis manifest apply <manifest_path>` shows the UCI changes that will be applied and asks for confirmation.
- `oasis manifest apply --yes <manifest_path>` applies the Manifest without an interactive prompt.

When preparing a package, save the generated JSON into the package's Manifest directory:

```
mkdir -p files/etc/oasis/tool-manifest.d
oasis manifest build files/usr/libexec/rpcd/<tool-server> > files/etc/oasis/tool-manifest.d/lua.<tool-server>.json
```

The setup helper also provides maintenance commands:

```
oasis_tool_setup rebuild-manifest
oasis_tool_setup refresh
```

- `rebuild-manifest` regenerates the Manifest store from installed Oasis-managed tool scripts. It does not generate `manual` Manifests.
- `refresh` rebuilds the runtime UCI tool registry from Manifest files.

## Lua OLT Server Example
This section presents an example of managing three tools within the tool group oasis.lua.template.tool.
In Lua, the tool group name corresponds to the script’s filename.  
To apply the Lua script, grant it executable permission and place it in /usr/libexec/rpcd
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

server.tool("oasis.ucode.template.tool1", "say_goodbye", {
    tool_desc: "Return a simple goodbye. No inputs.",
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

## How to Apply Tool Changes
When you add or update an rpcd script, make sure the corresponding Manifest exists under `/etc/oasis/tool-manifest.d/`.

If the rpcd script itself is new or changed, reload rpcd:

```
root@OpenWrt~# service olt_tool restart
root@OpenWrt~# service rpcd restart
```

After updating Manifest files, rebuild the runtime tool registry:

```
root@OpenWrt~# oasis_tool_setup refresh
```

## Recognition of Local Tools
Once Manifest files are applied and the runtime registry is refreshed, local tools become visible in the WebUI.
The image below shows an example of how the tools page appears in Oasis.
<img width="947" height="419" alt="image" src="https://github.com/user-attachments/assets/53b14416-4435-440c-b065-0276591010b8" />
<img width="947" height="392" alt="image" src="https://github.com/user-attachments/assets/98ce6ac1-e533-4b61-b32f-5a82279bc74d" />
<img width="947" height="140" alt="image" src="https://github.com/user-attachments/assets/5680e487-60a6-4f95-b323-1747bf7fd15c" />

## Script Tool Definition Fields
These fields are used inside Lua and ucode Oasis tool server scripts. During Manifest generation, Oasis maps script metadata fields to Manifest tool fields such as `description`, `properties`, `execution_message`, `download_message`, and `timeout`.

The `call` field is the actual tool implementation. It is required for runtime execution, but it is not exported as Manifest metadata.

| Param name | Desc | Required |
|----------|----------|----------|
| call    | Tool implementation function executed when the ubus method is called. | YES |
| args    | Tool parameter definitions used for validation and Manifest parameter generation. Not required if the tool does not take any arguments. | NO |
| tool_desc    | Tool overview description. The AI uses this information to understand what kind of tool it is. | YES |
| args_desc    | Explanation of tool parameters used by the AI to configure arguments during execution. Not required if the tool does not take any arguments. | NO |
| exec_msg    |  pre-execution message | NO |
| download_msg | download message and effect | NO |
| timeout | Optional timeout metadata used when calling the tool through ubus. | NO |

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
