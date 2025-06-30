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

local uci = require("luci.model.uci").cursor()
local jsonc = require("luci.jsonc")
local sys = require("luci.sys")
local fs = require("nixio.fs")

local ubus_server_app_dir = "/usr/libexec/rpcd"

local setup_server_config = function(server)

    local server_path = ubus_server_app_dir .. server
    local meta = sys.exec(server_path .. " meta")

    local data = jsonc.parse(meta)
    for _, tool in pairs(data) do
        local s = uci:section("oasis", "tool")
        uci:set("oasis", s, "server", server)
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

local list_rpcd_files = function()
  local files = fs.dir("/usr/libexec/rpcd")
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
    local scripts = list_rpcd_files()
    if scripts then
        for _, script in ipairs(scripts) do
            setup_server_config(script)
        end
    end
end

return {
    setup_server_config = setup_server_config,
    update_server_info = update_server_info,
}