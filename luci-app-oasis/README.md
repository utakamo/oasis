# Oasis Web API

This document describes the WebUI APIs exposed under LuCI by `module.lua` (shipped in the `oasis` package) and the CGI endpoint used by the chat UI.

## Overview

- The WebUI is provided by LuCI. Page templates are installed by `luci-app-oasis`; LuCI controller (`module.lua`) and CBI/CGI/UBUS live in the `oasis` package.
- It provides AI chat, configuration management (UCI apply/confirm/finalize/rollback), system messages, icons, local tools, and basic information.

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
  - `params` (string): Chat ID [ex: 6690019588]
- **Response**: JSON
- **Description**: Load data for the specified chat ID

POST request
```
let chatId = "6690019588";

fetch('<%=build_url("admin", "network", "oasis", "load-chat-data")%>', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ params: chatId })
})
```

#### 2.2 Import Chat Data
- **URL**: `/cgi-bin/luci/admin/network/oasis/import-chat-data`
- **Method**: POST
- **Parameters**:
  - `chat_data` (string): Base64 encoded chat data
- **Response**: JSON
- **Description**: Import chat data

POST request
```
const base64Data = /* file data (base64) */;

fetch('<%=build_url("admin", "network", "oasis", "import-chat-data")%>', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ chat_data: base64Data })
})
```

#### 2.3 Delete Chat Data
- **URL**: `/cgi-bin/luci/admin/network/oasis/delete-chat-data`
- **Method**: POST
- **Parameters**:
  - `params` (string): Chat ID
- **Response**: JSON
- **Description**: Delete the specified chat data

POST request
```
let chatId = "6690019588";
fetch('<%=build_url("admin", "network", "oasis", "delete-chat-data")%>', {
    method: "POST",
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ params: chatId }),
})
```

#### 2.4 Rename Chat
- **URL**: `/cgi-bin/luci/admin/network/oasis/rename-chat`
- **Method**: POST
- **Parameters**:
  - `id` (string): Chat ID
  - `title` (string): New title
- **Response**: JSON
- **Description**: Change the chat title

POST request
```
let chatId = "6690019588";
let newTitle = "new title!!"
fetch('<%=build_url("admin", "network", "oasis", "rename-chat")%>', {
    method: "POST",
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ id: chatId, title: newTitle })
})
```

#### 2.5 Chat CGI (streaming)
- **URL**: `/cgi-bin/oasis`
- **Method**: POST (Content-Type: application/json)
- **Body**:
  - `cmd`: "chat"
  - `id`: Chat ID
  - `message`: User message
  - `sysmsg_key`: System message key (e.g. `default`, `custom_1`, ...)
- **Response**: text stream
  - May first output a UCI notification JSON when configuration suggestions exist
  - Then outputs chat JSON messages

Request example
```
fetch(`${baseUrl}/cgi-bin/oasis`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ cmd: 'chat', id: targetChatId, message, sysmsg_key })
})
```

Output examples (multiple JSON objects can be streamed in sequence):

- UCI notification (when UCI command suggestions are detected)

```json
{
  "uci_notify": true,
  "uci_list": {
    "set": [
      {
        "param": "system.@system[0].hostname=duck",
        "class": {
          "config": "system",
          "section": "@system[0]",
          "option": "hostname",
          "value": "duck"
        }
      }
    ],
    "add": [],
    "add_list": [],
    "del_list": [],
    "delete": [],
    "reorder": []
  }
}
```

- Assistant message (streamed in chunks)

```json
{ "message": { "role": "assistant", "content": "Hello ..." } }
```

- Tool outputs (optional)

```json
{
  "service": "oasis.lua.tool.server",
  "tool_outputs": [
    {
      "tool_call_id": "123",
      "name": "get_weather",
      "output": "{\"user_only\":\"It's 22°C in Tokyo.\"}"
    }
  ]
}
```

- Progress events (optional)

```json
{ "type": "execution", "message": "Executing tool..." }
{ "type": "download",  "message": "Downloading..." }
```

- Reboot hint flag (optional)

```json
{ "reboot": true }
```

- Error fallback (single JSON on internal error)

```json
{ "message": { "role": "assistant", "content": "Internal error: oasis.output failed" } }
```

### 3. UCI Configuration Related APIs

#### 3.1 Apply UCI Commands
- **URL**: `/cgi-bin/luci/admin/network/oasis/apply-uci-cmd`
- **Method**: POST
- **Parameters**:
  - `uci_list` (string): JSON formatted UCI command list
  - `id` (string): Chat ID
  - `type` (string): "commit" or "normal"
- **Response**: JSON
- **Description**: Apply UCI commands proposed by AI

POST request
```
let uci_list = JSON.stringify(jsonResponse.uci_list);
let chatId = "6690019588";
let type = "commit";
fetch('<%=build_url("admin", "network", "oasis", "apply-uci-cmd")%>', {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ uci_list, id: chatId, type })
})
```

#### 3.2 Confirm Configuration
- **URL**: `/cgi-bin/luci/admin/network/oasis/confirm`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get configuration change confirmation status

#### 3.3 Finalize Configuration
- **URL**: `/cgi-bin/luci/admin/network/oasis/finalize`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Finalize configuration changes

#### 3.4 Rollback Configuration (flag)
- **URL**: `/cgi-bin/luci/admin/network/oasis/rollback`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Set rollback flag

#### 3.5 Show UCI Configuration
- **URL**: `/cgi-bin/luci/admin/network/oasis/uci-show`
- **Method**: POST
- **Parameters**:
  - `target` (string): UCI configuration name (e.g. `network`)
- **Response**: JSON (array of `uci show`-like strings)
- **Description**: Display the content of the specified UCI configuration

### 4. System Message Related APIs

#### 4.1 Load System Messages
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-sysmsg`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get system message list

#### 4.2 Update System Message
- **URL**: `/cgi-bin/luci/admin/network/oasis/update-sysmsg`
- **Method**: POST
- **Parameters**:
  - `target` (string): Target key to update
  - `title` (string): Title
  - `message` (string): Message content
- **Response**: JSON
- **Description**: Update system message

#### 4.3 Add System Message
- **URL**: `/cgi-bin/luci/admin/network/oasis/add-sysmsg`
- **Method**: POST
- **Parameters**:
  - `title` (string): Title
  - `message` (string): Message content
- **Response**: JSON
- **Description**: Add new system message

#### 4.4 Delete System Message
- **URL**: `/cgi-bin/luci/admin/network/oasis/delete-sysmsg`
- **Method**: POST
- **Parameters**:
  - `target` (string): Target key to delete
- **Response**: JSON
- **Description**: Delete system message

#### 4.5 Load External System Message
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-extra-sysmsg`
- **Method**: POST
- **Parameters**:
  - `url` (string): External URL
- **Response**: JSON
- **Description**: Load system message from external URL

### 5. Icon Related APIs

#### 5.1 Load Icon Information
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-icon-info`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get available icon list

#### 5.2 Select Icon
- **URL**: `/cgi-bin/luci/admin/network/oasis/select-icon`
- **Method**: POST
- **Parameters**:
  - `using` (string): Icon key to select
- **Response**: JSON
- **Description**: Select icon to use in AI chat

#### 5.3 Upload Icon
- **URL**: `/cgi-bin/luci/admin/network/oasis/upload-icon-data`
- **Method**: POST
- **Parameters**:
  - `filename` (string): Filename
  - `image` (string): Base64 encoded image data
- **Response**: JSON
- **Description**: Upload new icon image

#### 5.4 Delete Icon
- **URL**: `/cgi-bin/luci/admin/network/oasis/delete-icon-data`
- **Method**: POST
- **Parameters**:
  - `key` (string): Icon key to delete
- **Response**: JSON
- **Description**: Delete icon

### 6. AI Service Related APIs

#### 6.1 Select AI Service
- **URL**: `/cgi-bin/luci/admin/network/oasis/select-ai-service`
- **Method**: POST
- **Parameters**:
  - `identifier` (string): Service identifier
-  - `name` (string): Service name
  - `model` (string): Model name
- **Response**: JSON
- **Description**: Select AI service to use

### 7. Rollback Related APIs

#### 7.1 Load Rollback List
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-rollback-list`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON (list of rollbackable data; structure may contain categorized UCI operations)
- **Description**: Get list of rollbackable data

#### 7.2 Execute Rollback
- **URL**: `/cgi-bin/luci/admin/network/oasis/rollback-target-data`
- **Method**: POST
- **Parameters**:
  - `index` (string): Rollback target index
- **Response**: JSON
- **Description**: Rollback to specified data (device will reboot after success)

### 8. Basic Information APIs

#### 8.1 Get Basic Information
- **URL**: `/cgi-bin/luci/admin/network/oasis/base-info`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get basic information about icons, system messages, chats, services, and UCI configurations

### 9. Tool Related APIs

#### 9.1 Load Server Information
- **URL**: `/cgi-bin/luci/admin/network/oasis/local-tool-info`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON object:
  - `tools`: map of tool sections (UCI) with attributes such as `name`, `description`, `enable`, `type`, `script`, `server`, `conflict`, etc.
  - `server_info`: list of servers and their load status
  - `local_tool` (boolean): whether local tool feature is supported
- **Description**: Get tool server information and local tool definitions

#### 9.2 Enable Tool
- **URL**: `/cgi-bin/luci/admin/network/oasis/enable-tool`
- **Method**: POST
- **Parameters**:
  - `name` (string): Tool name
  - `server` (string): Server name (optional)
- **Response**: JSON
- **Description**: Enable a local tool (no-op when `conflict=1`)

#### 9.3 Disable Tool
- **URL**: `/cgi-bin/luci/admin/network/oasis/disable-tool`
- **Method**: POST
- **Parameters**:
  - `name` (string): Tool name
  - `server` (string): Server name (optional)
- **Response**: JSON
- **Description**: Disable a local tool

#### 9.4 Refresh Tools
- **URL**: `/cgi-bin/luci/admin/network/oasis/refresh-tools`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Restart related services (e.g. local tool server, rpcd)

#### 9.5 Add Remote MCP Server
- **URL**: `/cgi-bin/luci/admin/network/oasis/add-remote-mcp-server`
- **Method**: POST
- **Parameters**:
  - `name`, `server_label`, `type`, `server_url`, `require_approval`, `allowed_tools` (multi)
- **Response**: JSON
- **Description**: Add remote MCP server definition

#### 9.6 Remove Remote MCP Server
- **URL**: `/cgi-bin/luci/admin/network/oasis/remove-remote-mcp-server`
- **Method**: POST
- **Parameters**:
  - `name` (string): Section name to remove
- **Response**: JSON
- **Description**: Remove remote MCP server definition

### 10. System Functions

#### 10.1 System Reboot
- **URL**: `/cgi-bin/luci/admin/network/oasis/system-reboot`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON (`{ status: "OK" }` or `{ status: "NG" }`)
- **Description**: Trigger system reboot (available only when local tool support is enabled)

## Error Responses

All APIs return the following format when an error occurs:

```json
{
  "error": "Error message"
}
```

## Authentication

All APIs use the LuCI authentication system and can only be accessed by users with appropriate permissions.
