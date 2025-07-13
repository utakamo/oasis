--[[
# Note: How to retrieve tool list infomation
 - Ex1: Lua Script Ver) Target Tool Server ---> "oasis.lua.tool.server"
 - Ex2: uCode Script Ver) Target Tool Server ---> "oasis.ucode.tool.server1" and "oasis.ucode.tool.server2"

 1. Execute (Lua Script Ver):
 root@OpenWrt:~# /usr/libexec/rpcd/oasis.lua.tool.server meta

 2. Execute (uCode Script Ver):
 root@OpenWrt:~# ucode /usr/share/rpcd/ucode/oasis_plugin_server.uc

 Output(Example):
    {
        "get_weather": {
            "tool_desc": "Get current temperature for a given location.",
            "args_desc": [
                "City and country e.g. Bogotá, Colombia"
            ],
            "args": {
                "location": "a_string"
            }
        },
        "echo": {
            "tool_desc": "Echoes back the received parameters.",
            "args_desc": [
                "Parameter 1 (string)",
                "Parameter 2 (string)"
            ],
            "args": {
                "param1": "a_string",
                "param2": "a_string"
            }
        },
        "get_wlan_ifname_list": {
            "tool_desc": "Get the list of WLAN interface names.",
            "args_desc": {},
            "args": {}
        }
    }
]]

local uci       = require("luci.model.uci").cursor()
local common    = require("oasis.common")
local debug     = require("oasis.chat.debug")
local util      = require("luci.util")
local ubus      = require("ubus")
local jsonc     = require("luci.jsonc")
local sys       = require("luci.sys")
local fs        = require("nixio.fs")

local lua_ubus_server_app_dir = "/usr/libexec/rpcd/"
local ucode_ubus_server_app_dir = "/usr/share/rpcd/ucode/"

local setup_lua_server_config = function(server_name)
    local server_path = lua_ubus_server_app_dir .. server_name
    local meta = sys.exec(server_path .. " meta")

    -- Todo:
    -- Check meta command success

    local data = jsonc.parse(meta)

    if not data then
        debug:log("oasis-mod-tool.log", server_name .. " is not olt server...")
        return
    end

    debug:log("oasis-mod-tool.log", server_name .. " is olt server!!")

    local created_sections = {}

    for tool_name, tool in pairs(data) do
        local s = uci:section(common.db.uci.cfg, common.db.uci.sect.tool)
        uci:set(common.db.uci.cfg, s, "name", tool_name)
        uci:set(common.db.uci.cfg, s, "script", "lua")
        uci:set(common.db.uci.cfg, s, "server", server_name)
        uci:set(common.db.uci.cfg, s, "enable", "1")
        uci:set(common.db.uci.cfg, s, "type", "function")
        uci:set(common.db.uci.cfg, s, "description", tool.tool_desc or "")
        uci:set(common.db.uci.cfg, s, "conflict", "0")

        -- required parameter
        if tool.args then
            for param, _ in pairs(tool.args) do
                uci:set(common.db.uci.cfg, s, "required", param)
            end
        end
        uci:set(common.db.uci.cfg, s, "additionalProperties", "0")

        -- properties
        if tool.args then
            for param, typ in pairs(tool.args) do
                local desc = ""
                if tool.args_desc and type(tool.args_desc) == "table" then
                    desc = tool.args_desc[1] or ""
                end
                local type_map = { a_string = "string", integer = "number", boolean = "boolean" }
                local uci_type = type_map[typ] or typ
                uci:set(common.db.uci.cfg, s, "property", string.format("%s:%s:%s", param, uci_type, desc))
            end
        end
        table.insert(created_sections, {section = s, name = tool_name})
    end
    uci:commit(common.db.uci.cfg)
end

local setup_ucode_server_config = function(server_name)

    local server_path = ucode_ubus_server_app_dir .. server_name
    local meta = sys.exec("ucode " .. server_path)
    debug:log("oasis-mod-tool.log", meta)

    local data = jsonc.parse(meta)

    if not data then
        debug:log("oasis-mod-tool.log", "Script: " .. server_name .. " is not olt server...")
        return
    end

    local created_sections = {}

    for server, tbl in pairs(data) do
        for tool, def in pairs(tbl) do
            local s = uci:section(common.db.uci.cfg, common.db.uci.sect.tool)
            uci:set(common.db.uci.cfg, s, "name", tool)
            uci:set(common.db.uci.cfg, s, "script", "ucode")
            uci:set(common.db.uci.cfg, s, "server", server)
            uci:set(common.db.uci.cfg, s, "enable", "1")
            uci:set(common.db.uci.cfg, s, "type", "function")
            uci:set(common.db.uci.cfg, s, "description", def.tool_desc or "")
            uci:set(common.db.uci.cfg, s, "conflict", "0")

            -- required parameter
            if def.args then
                for param, _ in pairs(def.args) do
                    uci:set(common.db.uci.cfg, s, "required", param)
                end
            end
            uci:set(common.db.uci.cfg, s, "additionalProperties", "0")

            -- properties
            if def.args then
                for param, typ in pairs(def.args) do
                    local desc = ""
                    if def.args_desc and type(def.args_desc) == "table" then
                        desc = def.args_desc[1] or ""
                    end
                    local type_map = {}
                    type_map["8"] = "number"
                    type_map["16"] = "number"
                    type_map["32"] = "number"
                    type_map["64"] = "number"
                    type_map["true"] = "boolean"
                    type_map["false"] = "boolean"
                    type_map["string"] = "string"
                    local param_type = type_map[typ] or type_map.string
                    uci:set(common.db.uci.cfg, s, "property", string.format("%s:%s:%s", param, param_type, desc))
                end
            end
            table.insert(created_sections, {section = s, name = tool})
        end
    end
    uci:commit(common.db.uci.cfg)
end

local listup_server_candidate = function(dir)
  local files = fs.dir(dir)
  if not files then
    return nil
  end

  local result = {}
  for file in files do
    table.insert(result, file)
  end
  return result
end

local check_tool_name_conflict = function()
    -- Check Conflict Tool Name
    -- If the value of the conflict option is set to 1, usage will be prohibited.
    local name_to_sections = {}
    uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if s.name then
            name_to_sections[s.name] = name_to_sections[s.name] or {}
            table.insert(name_to_sections[s.name], s[".name"])
        end
    end)
    for _, sections in pairs(name_to_sections) do
        if #sections > 1 then
            for _, sec in ipairs(sections) do
                uci:set(common.db.uci.cfg, sec, "conflict", "1")
            end
        end
    end
end

local update_server_info = function()

    -- Initialize: delete all tool section
    uci:delete_all(common.db.uci.cfg, common.db.uci.sect.tool)
    uci:commit(common.db.uci.cfg)

    -- rpcd ubus server (Lua Script Ver)
    local lua_servers = listup_server_candidate(lua_ubus_server_app_dir)
    if lua_servers then
        for _, server_name in ipairs(lua_servers) do
            setup_lua_server_config(server_name)
        end
    end

    -- rpcd ubus server (uCode Script Ver)
    local ucode_servers = listup_server_candidate(ucode_ubus_server_app_dir)
    if ucode_servers then
        for _, server_name in ipairs(ucode_servers) do
            setup_ucode_server_config(server_name)
        end
    end

    check_tool_name_conflict()
end

-- This function is called when sending a message to the LLM.
local get_function_call_schema = function()
    local tools = {}

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if s.enable == "1" then
            local required = s.required or {}
            if type(required) == "string" then
                required = {required}
            end
            local additionalProperties = (s.additionalProperties == "1")
            -- Generate properties
            local properties = {}
            if s.property then
                local prop_list = s.property
                if type(prop_list) == "string" then
                    prop_list = {prop_list}
                end
                for _, prop in ipairs(prop_list) do
                    local name, typ, desc = prop:match("([^:]+):([^:]+):(.+)")
                    if name and typ then
                        properties[name] = { type = typ, description = desc or "" }
                    end
                end
            end
            local tool = {
                type = s.type or "function",
                name = s[".name"],
                description = s.description or "",
                parameters = {
                    type = "object",
                    properties = properties,
                    required = required,
                    additionalProperties = additionalProperties
                }
            }
            table.insert(tools, tool)
        end
    end)
    return tools
end


--[[
{
    "type": "function",
    "name": "get_weather",
    "description": "Get current temperature for a given location.",
    "parameters": {
        "type": "object",
        "properties": {
            "location": {
                "type": "string",
                "description": "City and country e.g. Bogotá, Colombia"
            }
        },
        "required": [
            "location"
        ],
        "additionalProperties": False
    }
}
]]

--[[
[Sample UCI Config]
config tool
    option name 'get_weather'
    option enable '1'
    option conflict '0'
    option server 'oasis.lua.tool.server'
    option type 'function'
    option description 'Get current temperature for a given location.'
    list required 'location'
    option additionalProperties '0'
    list property 'location:string:City and country e.g. Bogotá, Colombia'

config tool
    option name 'get_wlan_ifname_list'
    option enable '1'
    option conflict '0'
    option server 'oasis.lua.tool.server'
    option type 'function'
    option description 'Get the list of WLAN interface names.'
    option additionalProperties '0'

config tool
    option name 'echo'
    option enable '1'
    option conflict '0'
    option server 'oasis.lua.tool.server'
    option type 'function'
    option description 'Echoes back the received parameters.'
    list required 'param1'
    list required 'param2'
    option additionalProperties '0'
    list property 'param1:string:Parameter 1 (string)'
    list property 'param2:string:Parameter 2 (string)'
]]

--[[
 - [Json Data (OpenAI)] -
    {
    "id": "chatcmpl-xxxx",
    "object": "chat.completion",
    "choices": [
        {
        "index": 0,
        "message": {
            "role": "assistant",
            "content": null,
            "function_call": {
            "name": "echo",
            "arguments": "{ \"param1\": \"hello\", \"param2\": \"world\" }"
            }
        },
        "finish_reason": "function_call"
        }
    ],
    "created": 1234567890,
    "model": "gpt-4-0613"
    }

 - [Lua Table (OpenAI)] -
    local response = {
        id = "chatcmpl-xxxx",
        object = "chat.completion",
        choices = {
            {
                index = 0,
                message = {
                    role = "assistant",
                    content = nil,
                    function_call = {
                        name = "echo",
                        arguments = '{ "param1": "hello", "param2": "world" }'
                    }
                },
                finish_reason = "function_call"
            }
        },
        created = 1234567890,
        model = "gpt-4-0613"
    }
]]

local exec_server_tool = function(tool_name, data)
    local found = false
    local result = {}
    uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if s[".name"] == tool_name and s.enable == "1" then
            found = true
            local server = s.server
            result = util.ubus(server, tool_name, data)
            debug:log("oasis-mod-tool.log", string.format("Result for tool '%s': %s", tool_name, tostring(result)))
            return false
        end
    end)
    if not found then
        debug:log("oasis-mod-tool.log", string.format("Tool '%s' not found or not enabled.", tool_name))
    end

    return result
end

local function function_call(response)
    -- Todo: write some ai service code

    -- OpenAI
    local choice = response.choices[1]
    if choice and choice.message and choice.message.function_call then
        local tool_name = choice.message.function_call.name
        local args_json = choice.message.function_call.arguments
        local args = jsonc.parse(args_json)
        local result = exec_server_tool(tool_name, args)
        return result
    end
end

local function check_server_loaded(server_name)

    local conn = ubus.connect()
    if not conn then
        return false
    end

    local objects = conn:objects()
    for _, obj in ipairs(objects) do
        if obj == server_name then
            conn:close()
            return true
        end
    end

    conn:close()
    return false
end

return {
    setup_lua_server_config = setup_lua_server_config,
    setup_ucode_server_config = setup_ucode_server_config,
    update_server_info = update_server_info,
    get_function_call_schema = get_function_call_schema,
    function_call = function_call,
    check_server_loaded = check_server_loaded,
}