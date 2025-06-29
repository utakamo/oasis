#!/usr/bin/env lua

local uci = require("luci.model.uci").cursor()
local common = require("oasis.common")

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
[SAMPLE UCI CONFIG]
config tool 'get_weather'
    option enable '1'
    option type 'function'
    option description 'Get current temperature for a given location.'
    list required 'location'
    option additionalProperties '0'
    list property 'location:string:City and country e.g. Bogotá, Colombia'

config tool 'get_wlan_ifname_list'
    option enable '1'
    option type 'function'
    option description 'Get wireless lan interface name list.'
    option additionalProperties '0'

config tool 'function_A'
    option enable '1'
    option type 'function'
    option description 'Get current data A.'
    list required 'sample_parameter'
    option additionalProperties '0'
    list property 'sample_parameter:string:parameter description'
    list property 'another_param:number:another description'
]]

-- Function Calling - tools
local provide_tools = function()
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

local exec_tool = function(data)
    -- data.name: tool name
    -- data.parameters: parameter table
    if not data or not data.name then
        return { error = "tool name required" }
    end
    local tool_map = {
        get_wlan_ifname_list = get_wlan_ifname_list,
        function_A = function_A,
        get_weather = get_weather,
        -- Add other tool functions here as needed
    }
    local func = tool_map[data.name]
    if not func then
        return { error = "tool not found: " .. tostring(data.name) }
    end
    -- If parameters exist, unpack and pass them
    if data.parameters and type(data.parameters) == "table" then
        local ok, result = pcall(function() return func(table.unpack(data.parameters)) end)
        if ok then
            return { result = result }
        else
            return { error = result }
        end
    else
        local ok, result = pcall(func)
        if ok then
            return { result = result }
        else
            return { error = result }
        end
    end
end

return {
    provide_tools   = provide_tools,
    exec_tool       = exec_tool,
}