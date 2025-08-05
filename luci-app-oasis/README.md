> [!IMPORTANT]
> This Web API documentation is currently under development, so it may contain errors.

# Oasis Web API

This document describes the WebAPI specifications defined in `module.lua` managed by `luci-app-oasis`.

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
  - `params` (string): Chat ID
- **Response**: JSON
- **Description**: Load data for the specified chat ID

#### 2.2 Export Chat Data
- **URL**: `/cgi-bin/luci/admin/network/oasis/export-chat-data`
- **Method**: POST
- **Parameters**:
  - `params` (string): Chat ID
- **Response**: JSON
- **Description**: Export chat data

#### 2.3 Import Chat Data
- **URL**: `/cgi-bin/luci/admin/network/oasis/import-chat-data`
- **Method**: POST
- **Parameters**:
  - `chat_data` (string): Base64 encoded chat data
- **Response**: JSON
- **Description**: Import chat data

#### 2.4 Delete Chat Data
- **URL**: `/cgi-bin/luci/admin/network/oasis/delete-chat-data`
- **Method**: POST
- **Parameters**:
  - `params` (string): Chat ID
- **Response**: JSON
- **Description**: Delete the specified chat data

#### 2.5 Rename Chat
- **URL**: `/cgi-bin/luci/admin/network/oasis/rename-chat`
- **Method**: POST
- **Parameters**:
  - `id` (string): Chat ID
  - `title` (string): New title
- **Response**: JSON
- **Description**: Change the chat title

### 3. UCI Configuration Related APIs

#### 3.1 Apply UCI Commands
- **URL**: `/cgi-bin/luci/admin/network/oasis/apply-uci-cmd`
- **Method**: POST
- **Parameters**:
  - `uci_list` (string): JSON formatted UCI command list
  - `id` (string): Chat ID
  - `type` (string): Application type ("commit" or "normal")
- **Response**: JSON
- **Description**: Apply UCI commands proposed by AI

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

#### 3.4 Rollback Configuration
- **URL**: `/cgi-bin/luci/admin/network/oasis/rollback`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Rollback configuration changes

#### 3.5 Show UCI Configuration
- **URL**: `/cgi-bin/luci/admin/network/oasis/uci-show`
- **Method**: POST
- **Parameters**:
  - `target` (string): UCI configuration name
- **Response**: JSON
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
  - `name` (string): Service name
  - `model` (string): Model name
- **Response**: JSON
- **Description**: Select AI service to use

### 7. Rollback Related APIs

#### 7.1 Load Rollback List
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-rollback-list`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get list of rollbackable data

#### 7.2 Execute Rollback
- **URL**: `/cgi-bin/luci/admin/network/oasis/rollback-target-data`
- **Method**: POST
- **Parameters**:
  - `index` (string): Rollback target index
- **Response**: JSON
- **Description**: Rollback to specified data (reboot will be executed)

### 8. Basic Information APIs

#### 8.1 Get Basic Information
- **URL**: `/cgi-bin/luci/admin/network/oasis/base-info`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get basic information about icons, system messages, chats, services, and UCI configurations

### 9. Tool Related APIs

#### 9.1 Load Local Tools Information
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-local-tools-info`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get list of local tools

#### 9.2 Toggle Tool Enable/Disable
- **URL**: `/cgi-bin/luci/admin/network/oasis/change-tool-enable`
- **Method**: POST
- **Parameters**:
  - `name` (string): Tool name
  - `enable` (string): "0" (disable) or "1" (enable)
- **Response**: JSON
- **Description**: Toggle tool enable/disable status

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

#### 9.4 Remove Remote MCP Server
- **URL**: `/cgi-bin/luci/admin/network/oasis/remove-remote-mcp-server`
- **Method**: POST
- **Parameters**:
  - `name` (string): Server name to remove
- **Response**: JSON
- **Description**: Remove remote MCP server

#### 9.5 Load Server Information
- **URL**: `/cgi-bin/luci/admin/network/oasis/load-server-info`
- **Method**: POST
- **Parameters**: None
- **Response**: JSON
- **Description**: Get tool server information

## Error Responses

All APIs return the following format when an error occurs:

```json
{
  "error": "Error message"
}
```

## Authentication

All APIs use the LuCI authentication system and can only be accessed by users with appropriate permissions.

## Dependencies

- OpenWrt LuCI framework
- oasis core library
- ubus RPC system
