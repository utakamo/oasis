--[[
# Note: How to retrieve tool list infomation
 Target Tool Server ---> "oasis.util.tool.server"

 Execute:
 root@OpenWrt:~# /usr/libexec/rpcd/oasis.util.tool.server meta

 Output:
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

local ubus_server_app_dir = "/usr/libexec/rpcd"

local setup_server_config = function(server_name)

    local server_path = ubus_server_app_dir .. server_name
    local meta = sys.exec(server_path .. " meta")

    -- Todo:
    -- Check meta command success

    local data = jsonc.parse(meta)

    for _, tool in pairs(data) do
        local s = uci:section("oasis", "tool")
        uci:set("oasis", s, "server", server_name)
        uci:set("oasis", s, "enable", "1")
        uci:set("oasis", s, "type", "function")
        uci:set("oasis", s, "description", tool.tool_desc or "")

        -- required parameter
        if tool.args then
            for param, _ in pairs(tool.args) do
                uci:add("oasis", s, "required", param)
            end
        end
        uci:set("oasis", s, "additionalProperties", "0")

        -- properties
        if tool.args then
            for param, typ in pairs(tool.args) do
                local desc = ""
                if tool.args_desc and type(tool.args_desc) == "table" then
                    desc = tool.args_desc[1] or ""
                end
                local type_map = { a_string = "string", integer = "number", boolean = "boolean" }
                local uci_type = type_map[typ] or typ
                uci:add("oasis", s, "property", string.format("%s:%s:%s", param, uci_type, desc))
            end
        end
    end
    uci:commit("oasis")
end

local listup_server_candidate = function()
  local files = fs.dir(ubus_server_app_dir)
  if not files then
    return nil
  end

  local result = {}
  for file in files do
    table.insert(result, file)
  end
  return result
end

local update_server_info = function()
    local servers = listup_server_candidate()
    if servers then
        for _, server_name in ipairs(servers) do
            setup_server_config(server_name)
        end
    end
end

-- This function is called when sending a message to the LLM.
local get_function_call_schema = function()
    local tools = {}

    uci:foreach(common.db.uci.config, common.db.uci.sect.tool, function(s)
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
config tool 'get_weather'
    option enable '1'
    option conflict '0'
    option server 'oasis.util.tool.server'
    option type 'function'
    option description 'Get current temperature for a given location.'
    list required 'location'
    option additionalProperties '0'
    list property 'location:string:City and country e.g. Bogotá, Colombia'

config tool 'get_wlan_ifname_list'
    option enable '1'
    option conflict '0'
    option server 'oasis.util.tool.server'
    option type 'function'
    option description 'Get the list of WLAN interface names.'
    option additionalProperties '0'

config tool 'echo'
    option enable '1'
    option conflict '0'
    option server 'oasis.util.tool.server'
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
    uci:foreach("oasis", "tool", function(s)
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
    setup_server_config = setup_server_config,
    update_server_info = update_server_info,
    get_function_call_schema = get_function_call_schema,
    function_call = function_call,
    check_server_loaded = check_server_loaded,
}