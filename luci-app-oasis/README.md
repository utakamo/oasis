# Oasis Web API

This document describes the WebAPI specifications defined in `module.lua` managed by `oasis` package.

## Overview

`module.lua` is a Lua script-based WebAPI created based on the OpenWrt LuCI framework. It provides WebUI functionality for the Oasis application and supports various operations such as AI chat, configuration management, and tool functionality.

## Basic Information

- **Base URL**: `/cgi-bin/luci/admin/network/oasis/`
- **Authentication**: Uses LuCI authentication system
- **Response Format**: JSON
- **Encoding**: UTF-8

## WebAPI List

### 1. Page Templates

#### 1.1 Main Page
- **URL**: `/cgi-bin/luci/admin/network/oasis`
- **Method**: GET
- **Description**: Oasis main page

#### 1.2 Chat Page
- **URL**: `/cgi-bin/luci/admin/network/oasis/chat`
- **Method**: GET
- **Description**: AI chat interface

#### 1.3 Settings Page
- **URL**: `/cgi-bin/luci/admin/network/oasis/setting`
- **Method**: GET
- **Description**: General settings interface

#### 1.4 System Message Page
- **URL**: `/cgi-bin/luci/admin/network/oasis/sysmsg`
- **Method**: GET
- **Description**: System message management interface

#### 1.5 Rollback List Page
- **URL**: `/cgi-bin/luci/admin/network/oasis/rollback-list`
- **Method**: GET
- **Description**: Rollback data list interface

#### 1.6 Tools Page
- **URL**: `/cgi-bin/luci/admin/network/oasis/tools`
- **Method**: GET
- **Description**: Tool management interface

#### 1.7 Icons Page
- **URL**: `/cgi-bin/luci/admin/network/oasis/icons`
- **Method**: GET
- **Description**: AI icon settings interface

### 2. Chat Related APIs

#### 2.1 Load Chat Data
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-chat-data`
- **Method**: POST
- **Parameters**:
  - `params` (string): Chat ID [ex: 6690019588] *It's an 11-digit number.
- **Response**: JSON
- **Description**: Load data for the specified chat ID

**POST request**  
```
let chatID = "6690019588"

fetch('<%=build_url("admin", "network", "oasis", "load-chat-data")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ params: chatId })
})
```
**Output**  
`
{
        "messages": [
                {
                        "content": "Feel free to talk with the user.",
                        "role": "system"
                },
                {
                        "content": "Hello",
                        "role": "user"
                },
                {
                        "content": "Hey there! 👋 What's going on?  😄 \n",
                        "role": "assistant"
                },
                {
                        "content": "I'm a developer of Oasis. Nice to meet you.",
                        "role": "user"
                },
                {
                        "content": "That's awesome! 😊 It's great to meet another developer, especially one working on something as cool as Oasis!  \n\nWhat kind of projects are you working on within the project?  Are you focusing on specific areas like blockchain, smart contracts, or user experience? \n\n\nI'd love to hear more about your work! ✨  \n",
                        "role": "assistant"
                }
        ]
}
`

#### 2.2 Import Chat Data
- **URL**: `/cgi-bin/luci/admin/network/oasis/import-chat-data`
- **Method**: POST
- **Parameters**:
  - `chat_data` (string): Base64 encoded chat data
- **Response**: JSON
- **Description**: Import chat data

**POST request**  
```
const base64Data = <file data>

fetch('<%=build_url("admin", "network", "oasis", "import-chat-data")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ chat_data: base64Data })
})
```
**Output**  
`
{
  "id": "5574518533",
  "title": "--"
}
`
> [!NOTE]
> When chat data is successfully imported, it is assigned an 11-digit ID and saved with the title name '--'.

#### 2.3 Delete Chat Data
- **URL**: `/cgi-bin/luci/admin/network/oasis/delete-chat-data`
- **Method**: POST
- **Parameters**:
  - `params` (string): Chat ID [ex: 6690019588] *It's an 11-digit number.
- **Response**: JSON
- **Description**: Delete the specified chat data

**POST request**  
```
let chatId = "6690019588";
fetch('<%=build_url("admin", "network", "oasis", "delete-chat-data")%>', {
    method: "POST",
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({ params: chatId }),
})
```
**Output**  
`
{
        "status": "OK"
}
`

#### 2.4 Rename Chat
- **URL**: `/cgi-bin/luci/admin/network/oasis/rename-chat`
- **Method**: POST
- **Parameters**:
  - `id` (string): Chat ID [ex: 6690019588] *It's an 11-digit number.
  - `title` (string): New title
- **Response**: JSON
- **Description**: Change the chat title

**POST request**  
```
let chatId = "6690019588";
let newTitle = "new title!!"
fetch('<%=build_url("admin", "network", "oasis", "rename-chat")%>', {
    method: "POST",
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ id: chatId, title: newTitle })
})
```
**Output**  
`
{
        "status": "OK",
        "title": "new title!!"
}
`

### 3. UCI Configuration Related APIs

#### 3.1 Apply UCI Commands
- **URL**: `/cgi-bin/luci/admin/network/oasis/apply-uci-cmd`
- **Method**: POST
- **Parameters**:
  - `uci_list` (string): JSON formatted UCI command list
  - `id` (string): Chat ID [ex: 6690019588] *It's an 11-digit number.
  - `type` (string): Application type ("commit" or "normal")
- **Response**: JSON
- **Description**: Apply UCI commands proposed by AI

**POST request**  
```
let uci_list = JSON.stringify(jsonResponse.uci_list);
let chatId = "6690019588";
let type = "commit"

fetch('<%=build_url("admin", "network", "oasis", "apply-uci-cmd")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({uci_list : uci_list, id : chatId, type : type})
})
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

#### 3.2 Confirm Configuration
- **URL**: `/cgi-bin/luci/admin/network/oasis/confirm`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get configuration change confirmation status

**POST request**  
```
fetch('<%=build_url("admin", "network", "oasis", "confirm")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    }
})
```
**Output**  
`
{ "status": "OK", "uci_list": "{\"delete\":[],\"set\":[{\"param\":\"system.@system[0].hostname=duck\",\"class\":{\"option\":\"hostname\",\"config\":\"system\",\"value\":\"duck\",\"section\":\"@system[0]\"}}],\"del_list\":[],\"add\":[],\"reorder\":[],\"add_list\":[]}" }
`

#### 3.3 Finalize Configuration
- **URL**: `/cgi-bin/luci/admin/network/oasis/finalize`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Finalize configuration changes
**POST request**  
```
fetch('<%=build_url("admin", "network", "oasis", "finalize")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    }
})
```
**Output**
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

#### 3.4 Rollback Configuration
- **URL**: `/cgi-bin/luci/admin/network/oasis/rollback`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Rollback configuration changes

**POST request**  
```
fetch('<%=build_url("admin", "network", "oasis", "rollback")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    }
})
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

#### 3.5 Show UCI Configuration
- **URL**: `/cgi-bin/luci/admin/network/oasis/uci-show`
- **Method**: POST
- **Parameters**:
  - `target` (string): UCI configuration name
- **Response**: JSON
- **Description**: Display the content of the specified UCI configuration

**POST request**  
```
let target = "network";
fetch('<%=build_url("admin", "network", "oasis", "uci-show")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ target: target })
});
```
**Output**  
`
[ "network.@device[0]=device", "network.@device[0].name=br-lan", "network.@device[0].ports=lan1 lan2 lan3 lan4 ", "network.@device[0].type=bridge", "network.globals=globals", "network.globals.ula_prefix=fd97:fa3d:38ff::/48", "network.lan.ipaddr=192.168.1.1", "network.lan.device=br-lan", "network.lan.ip6assign=60", "network.lan=interface", "network.lan.netmask=255.255.255.0", "network.lan.proto=static", "network.loopback=interface", "network.loopback.ipaddr=127.0.0.1", "network.loopback.netmask=255.0.0.0", "network.loopback.device=lo", "network.loopback.proto=static", "network.wan=interface", "network.wan.device=wan", "network.wan.proto=dhcp", "network.wan6=interface", "network.wan6.device=wan", "network.wan6.proto=dhcpv6" ]
`

### 4. System Message Related APIs

#### 4.1 Load System Messages
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-sysmsg`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get system message list
**POST request**  
```
fetch('<%=build_url("admin", "network", "oasis", "load-sysmsg")%>', {
    method: 'POST',
})
```
**Output**  
`
{ "custom_2": { "title": "OpenWrt Network Knowledge (Sample)", "chat": "You are an AI that listens to user requests and suggests changes to OpenWrt settings.\\nWhen a user requests changes to network or Wi-Fi settings, please suggest the OpenWrt UCI commands that will achieve the user's expected settings.\\nIf the user asks questions unrelated to OpenWrt settings, there is no need to answer about OpenWrt settings.\\nRegarding network and Wi-Fi settings using OpenWrt UCI commands, I will teach you the following basic content.\\n[1] Setup AP setting\\nStep1: Activate Wi-Fi\\n```\\nuci set wireless.radio0.disabled=0\\nuci set wireless.radio0.country=JP\\nuci set wireless.radio0.txpower=10\\nuci set wireless.default_radio0.ssid=OpenWrt\\nuci set wireless.default_radio0.encryption=psk2\\nuci set wireless.default_radio0.key=OpenWrt1234\\n```\\nThe value of wireless.default_radio0.key should be an appropriate string in the following format.\\nFormat: alphanumeric characters + special characters, 8~63 characters\\nStep2: Accept IP address assignment by DHCP server.\\n```\\nuci set network.lan.proto=dhcp\\n```\\n[2] Setup Basic Router setting\\nStep1: Activate Wi-Fi\\n```\\nuci set wireless.radio0.disabled=0\\nuci set wireless.radio0.country=JP\\nuci set wireless.radio0.txpower=10\\nuci set wireless.default_radio0.encryption=psk2\\nuci set wireless.default_radio0.key=OpenWrt1234\\n```\\nStep2: Setup LAN segment network\\n```\\nuci set network.lan.device=wlan0\\nuci set network.lan.ipaddr=192.168.4.1\\n```\\n'uci set network.lan.ipaddr=192.168.4.1' is the LAN-side IP address of the router.\\nIn this example, it's set to 192.168.4.1, but if the user specifies a different IP address,\\nplease follow their instructions.\\nStep3: Setup WAN segment network\\n```\\nuci set network.wan=interface\\nuci set network.wan.device=eth0\\nuci set network.wan.proto=dhcp\\n```\\nIn the initial settings, there is no 'wan' section in the network configuration,\\nso you need to create a new 'wan' section by executing 'uci set network.wan=interface'.\\n" }, "default": { "prompt": "Please respond to the user briefly and appropriately.", "title": "OpenWrt Teacher (for High-Performance LLM)", "chat": "You are an OpenWrt teacher. \\nPlease answer users' questions politely. Also, when a user requests a configuration change, please provide instructions on how to change the settings using UCI commands. \\n\\nThe UCI commands that you output as code are executed by software called Oasis. \\nWhen Oasis runs UCI commands, it automatically executes the relevant uci commit command and /etc/init.d scripts.\\n\\nTherefore, you do not need to display the uci commit command to the user.\\n" }, "custom_1": { "title": "OpenWrt System Knowledge (Sample)", "chat": "Execute the uci set command in response to a user's request to change settings. By providing the execution sequence of the uci set command as code, the content is interpreted and automatically executed on the receiving OpenWrt system.\\n\\nIf the user does not specify any particular settings to change, notify them of the following possible changes:\\n\\nChanging the UI Theme Changing the Hostname\\n\\n## 1. Changing the UI Theme\\nPropose a UI theme change according to the user's request. The available UI themes are managed as values in the Bootstrap section, as shown below:\\n\\n```\\nluci.themes.Bootstrap='/luci-static/bootstrap'\\nluci.themes.BootstrapDark='/luci-static/bootstrap-dark'\\nluci.themes.BootstrapLight='/luci-static/bootstrap-light'\\n```\\n\\nIn the above example, users can choose from three options: bootstrap, bootstrap-dark, and bootstrap-light. \\nTo set the UI theme to bootstrap, the following command must be executed:\\n\\nuci set luci.main.mediaurlbase='/luci-static/bootstrap'\\nNotify users of the available themes and modify the luci.main.mediaurlbase value using the uci set command as per the user's instructions.\\n\\n## 2. Changing the Hostname\\nThe hostname can be changed by executing the uci set command. Below is an example of changing the hostname to \\\"OpenWrt\\\":\\n\\n```\\nuci set system.@system[0].hostname=OpenWrt\\n```\\n\\nAsk the user for the desired hostname and provide the command above." }, "icons": { "using": "icon_1", "path": "/www/luci-static/resources/oasis/", "icon_1": "openwrt.png", "icon_2": "operator.png" }, "custom_3": { "title": "free", "chat": "Feel free to talk with the user." }, "general": { "auto_title": "Please title the conversation so far. Please use only the title name in your response. Do not include any text not related to the title." } }
`

#### 4.2 Update System Message
- **URL**: `/cgi-bin/luci/admin/network/oasis/update-sysmsg`
- **Method**: POST
- **Parameters**:
  - `target` (string): Target key to update
  - `title` (string): Title
  - `message` (string): Message content
- **Response**: JSON
- **Description**: Update system message

**POST request**  
```
fetch('<%=build_url("admin", "network", "oasis", "update-sysmsg")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({ target: target, title: title, message: message }),
})
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

#### 4.3 Add System Message
- **URL**: `/cgi-bin/luci/admin/network/oasis/add-sysmsg`
- **Method**: POST
- **Parameters**:
  - `title` (string): Title
  - `message` (string): Message content
- **Response**: JSON
- **Description**: Add new system message

**POST request**  
```
let title = "Computer Science Teacher"
let message =  "You are a computer science teacher. Please answer users' computer-related questions politely.";
message = message.replace(/"/g, '\\"');

fetch('<%=build_url("admin", "network", "oasis", "add-sysmsg")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({ title: title, message: message }),
})
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

#### 4.4 Delete System Message
- **URL**: `/cgi-bin/luci/admin/network/oasis/delete-sysmsg`
- **Method**: POST
- **Parameters**:
  - `target` (string): Target key to delete
- **Response**: JSON
- **Description**: Delete system message

**POST request**  
```
let target = "custom_1";
fetch('<%=build_url("admin", "network", "oasis", "delete-sysmsg")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({ target: target }),
})
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

#### 4.5 Load External System Message
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-extra-sysmsg`
- **Method**: POST
- **Parameters**:
  - `url` (string): External URL
- **Response**: JSON
- **Description**: Load system message from external URL

**POST request**  
```
let url = "https://example.com/system-message.json";
fetch('<%=build_url("admin", "network", "oasis", "load-extra-sysmsg")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ url: url })
})
```
**Output**  
`
{
  "sysmsg": "External system message content"
}
`

### 5. Icon Related APIs

#### 5.1 Load Icon Information
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-icon-info`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get available icon list

**POST request**  
```
fetch('<%=build_url("admin", "network", "oasis", "load-icon-info")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    }
})
```
**Output**  
`
{
  "using": "icon_1",
  "path": "/www/luci-static/resources/oasis/",
  "icon_1": "openwrt.png",
  "icon_2": "operator.png"
}
`

#### 5.2 Select Icon
- **URL**: `/cgi-bin/luci/admin/network/oasis/select-icon`
- **Method**: POST
- **Parameters**:
  - `using` (string): Icon key to select
- **Response**: JSON
- **Description**: Select icon to use in AI chat

**POST request**  
```
let using = "icon_2";
fetch('<%=build_url("admin", "network", "oasis", "select-icon")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ using: using })
})
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

#### 5.3 Upload Icon
- **URL**: `/cgi-bin/luci/admin/network/oasis/upload-icon-data`
- **Method**: POST
- **Parameters**:
  - `filename` (string): Filename
  - `image` (string): Base64 encoded image data
- **Response**: JSON
- **Description**: Upload new icon image

**POST request**  
```
let filename = "my_icon.png";
let image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="; // Base64 encoded image

fetch('<%=build_url("admin", "network", "oasis", "upload-icon-data")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ 
        filename: filename, 
        image: image 
    })
})
```
**Output**  
`
{
  "key": "icon_3"
}
`

#### 5.4 Delete Icon
- **URL**: `/cgi-bin/luci/admin/network/oasis/delete-icon-data`
- **Method**: POST
- **Parameters**:
  - `key` (string): Icon key to delete
- **Response**: JSON
- **Description**: Delete icon

**POST request**  
```
let key = "icon_2";
fetch('<%=build_url("admin", "network", "oasis", "delete-icon-data")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ key: key })
})
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

### 6. AI Service Related APIs

#### 6.1 Select AI Service
- **URL**: `/cgi-bin/luci/admin/network/oasis/select-ai-service`
- **Method**: POST
- **Parameters**:
  - `identifier` (string): Service identifier
  - `name` (string): Service name
  - `model` (string): Model name
- **Response**: JSON
- **Description**: Select AI service to use

**POST request**  
```
let identifier = "7594872593";
let name = "Ollama";
let model = "gemma2:2b";

fetch('<%=build_url("admin", "network", "oasis", "select-ai-service")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ 
        identifier: identifier, 
        name: name, 
        model: model 
    })
})
```
**Output**  
`
{
  "status": "OK"
}
`

### 7. Rollback Related APIs

#### 7.1 Load Rollback List
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-rollback-list`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get list of rollbackable data

**POST request**  
```
fetch('<%=build_url("admin", "network", "oasis", "load-rollback-list")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    }
})
```
**Output**  
`
[
  {
    "index": "0",
    "timestamp": "2024-01-15 10:30:00",
    "description": "Network configuration backup"
  },
  {
    "index": "1", 
    "timestamp": "2024-01-14 15:45:00",
    "description": "System settings backup"
  }
]
`

#### 7.2 Execute Rollback
- **URL**: `/cgi-bin/luci/admin/network/oasis/rollback-target-data`
- **Method**: POST
- **Parameters**:
  - `index` (string): Rollback target index
- **Response**: JSON
- **Description**: Rollback to specified data (reboot will be executed)

**POST request**  
```
let index = "0";
fetch('<%=build_url("admin", "network", "oasis", "rollback-target-data")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ index: index })
})
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.
> [!WARNING]
> This operation will trigger a system reboot after successful rollback.

### 8. Basic Information APIs

#### 8.1 Get Basic Information
- **URL**: `/cgi-bin/luci/admin/network/oasis/base-info`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get basic information about icons, system messages, chats, services, and UCI configurations
**POST request**  
```
fetch('<%=build_url("admin", "network", "oasis", "base-info")%>', {
    method: 'POST'
})
```
**Output**  
`
{ "sysmsg": [ { "key": "default", "title": "OpenWrt Teacher (for High-Performance LLM)" }, { "key": "custom_1", "title": "OpenWrt System Knowledge (Sample)" }, { "key": "custom_2", "title": "OpenWrt Network Knowledge (Sample)" }, { "key": "custom_3", "title": "free" } ], "configs": [ "dhcp", "dropbear", "firewall", "luci", "network", "system", "ubihealthd", "ubootenv", "uhttpd", "wireless" ], "service": [ { "identifier": "7594872593", "name": "Ollama", "model": "gemma2:2b" } ], "icon": { "list": { "icon_1": "openwrt.png", "icon_2": "operator.png" }, "ctrl": { "using": "icon_1", "path": "/www/luci-static/resources/oasis/" } }, "chat": { "item": [ { "id": "3496377892", "title": "はじめてのOpenWrt" }, { "id": "6690019588", "title": "ConversationwithaNewFriend😊" }, { "id": "4607706843", "title": "SettingHostnameandUITheme" } ] } }
`

### 9. Tool Related APIs

#### 9.1 Load Local Tools Information
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-local-tools-info`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get list of local tools

**POST request**  
```
fetch('<%=build_url("admin", "network", "oasis", "load-local-tools-info")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    }
})
```
**Output**  
`
[
  {
    "name": "get_weather",
    "description": "Get current temperature for a given location.",
    "enable": "1",
    "type": "function"
  }
]
`

#### 9.2 Toggle Tool Enable/Disable
- **URL**: `/cgi-bin/luci/admin/network/oasis/change-tool-enable`
- **Method**: POST
- **Parameters**:
  - `name` (string): Tool name
  - `enable` (string): "0" (disable) or "1" (enable)
- **Response**: JSON
- **Description**: Toggle tool enable/disable status

**POST request**  
```
POST /cgi-bin/luci/admin/network/oasis/change-tool-enable
Content-Type: application/x-www-form-urlencoded

name=get_weather&enable=1
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

#### 9.3 Add Remote MCP Server
- **URL**: `/cgi-bin/luci/admin/network/oasis/add-remote-mcp-server`
- **Method**: POST
- **Parameters**:
  - `name` (string): Server name
  - `server_label` (string): Server label
  - `type` (string): Server type
  - `server_url` (string): Server URL
  - `require_approval` (string): Approval required flag
  - `allowed_tools` (array): List of allowed tools
- **Response**: JSON
- **Description**: Add remote MCP server

**POST request**  
```
let formData = new FormData();
formData.append('name', 'my_server');
formData.append('server_label', 'My Custom Server');
formData.append('type', 'http');
formData.append('server_url', 'https://example.com/mcp');
formData.append('require_approval', '1');
formData.append('allowed_tools', 'tool1');
formData.append('allowed_tools', 'tool2');

fetch('<%=build_url("admin", "network", "oasis", "add-remote-mcp-server")%>', {
    method: 'POST',
    body: formData
})
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

#### 9.4 Remove Remote MCP Server
- **URL**: `/cgi-bin/luci/admin/network/oasis/remove-remote-mcp-server`
- **Method**: POST
- **Parameters**:
  - `name` (string): Server name to remove
- **Response**: JSON
- **Description**: Remove remote MCP server

**POST request**  
```
let name = "my_server";
fetch('<%=build_url("admin", "network", "oasis", "remove-remote-mcp-server")%>', {
    method: 'POST',
    headers: {
        'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: new URLSearchParams({ name: name })
})
```
**Output**  
`
{
  "status": "OK"
}
`
> [!NOTE]
> This API returns a fixed JSON object with status "OK" on success.

#### 9.5 Load Server Information
- **URL**: `/cgi-bin/luci/admin/network/oasis/local-tool-info`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get tool server information
**POST request**  
```
fetch('<%=build_url("admin", "network", "oasis", "local-tool-info")%>')
```
**Output**
`
{ "tools": { "cfg129263": { ".name": "cfg129263", ".anonymous": true, "script": "ucode", "enable": "1", "type": "function", "additionalProperties": "0", "required": "foo", ".index": 17, "name": "method_2", "description": "This is test tool No.2", "conflict": "0", "property": "foo:string:sample Integer parameter.", ".type": "tool", "server": "oasis.ucode.tool.server1" }, "cfg0f9263": { ".name": "cfg0f9263", ".anonymous": true, "script": "lua", "enable": "1", "additionalProperties": "0", ".index": 14, "name": "get_wlan_ifname_list", "description": "Get the list of WLAN interface names.", "conflict": "0", "type": "function", ".type": "tool", "server": "oasis.lua.tool.server" }, "cfg0d9263": { ".name": "cfg0d9263", ".anonymous": true, "script": "lua", "enable": "1", "type": "function", "additionalProperties": "0", "required": "param2", ".index": 12, "name": "echo", "description": "Echoes back the received parameters.", "conflict": "0", "property": "param2:string:Parameter 1 (string)", ".type": "tool", "server": "oasis.lua.tool.server" }, "cfg119263": { ".name": "cfg119263", ".anonymous": true, "script": "ucode", "enable": "1", "additionalProperties": "0", ".index": 16, "name": "method_3", "description": "This is test tool No.1", "conflict": "0", "type": "function", ".type": "tool", "server": "oasis.ucode.tool.server2" }, "cfg0e9263": { ".name": "cfg0e9263", ".anonymous": true, "script": "lua", "enable": "1", "type": "function", "additionalProperties": "0", "required": "location", ".index": 13, "name": "get_weather", "description": "Get current temperature for a given location.", "conflict": "0", "property": "location:string:City and country e.g. Bogotá, Colombia", ".type": "tool", "server": "oasis.lua.tool.server" }, "cfg139263": { ".name": "cfg139263", ".anonymous": true, "script": "ucode", "enable": "1", "additionalProperties": "0", ".index": 18, "name": "method_1", "description": "This is test tool No.1", "conflict": "0", "type": "function", ".type": "tool", "server": "oasis.ucode.tool.server1" }, "cfg109263": { ".name": "cfg109263", ".anonymous": true, "script": "ucode", "enable": "1", "additionalProperties": "0", ".index": 15, "name": "method_4", "description": "This is test tool No.2", "conflict": "0", "type": "function", ".type": "tool", "server": "oasis.ucode.tool.server2" } }, "server_info": [ { "name": "oasis.ucode.tool.server1", "status": "loaded" }, { "name": "oasis.lua.tool.server", "status": "loaded" }, { "name": "oasis.ucode.tool.server2", "status": "loaded" } ] }
`

## Error Responses

All APIs return the following format when an error occurs:

```json
{
  "error": "Error message"
}
```

## Authentication

All APIs use the LuCI authentication system and can only be accessed by users with appropriate permissions.
