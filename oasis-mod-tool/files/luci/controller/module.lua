local sys           = require("luci.sys")
local util          = require("luci.util")
local uci           = require("luci.model.uci").cursor()
local luci_http     = require("luci.http")
local jsonc         = require("luci.jsonc")
local oasis         = require("oasis.chat.apply")
local common        = require("oasis.common")
local transfer      = require("oasis.chat.transfer")
local misc          = require("oasis.chat.misc")
local datactrl      = require("oasis.chat.datactrl")
local nixio         = require("nixio")
local oasis_ubus    = require("oasis.ubus.util")
local debug         = require("oasis.chat.debug")

module("luci.controller.oasis-tool.module", package.seeall)

function index()

    local is_webui_support = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "webui")

    if not is_webui_support then
        return
    end

    entry({"admin", "network", "oasis", "tools"}, template("oasis/tools"), "Tools", 50).dependent=false
    entry({"admin", "network", "oasis", "change-tool-enable"}, call("change_tool_enable"), nil).leaf = true
    entry({"admin", "network", "oasis", "enable-tool"}, call("enable_tool"), nil).leaf = true
    entry({"admin", "network", "oasis", "disable-tool"}, call("disable_tool"), nil).leaf = true
    entry({"admin", "network", "oasis", "add-remote-mcp-server"}, call("add_remote_mcp_server"), nil).leaf = true
    entry({"admin", "network", "oasis", "remove-remote-mcp-server"}, call("remove_remote_mcp_server"), nil).leaf = true
	entry({"admin", "network", "oasis", "local-tool-info"}, call("local_tool_info"), nil).leaf = true
	entry({"admin", "network", "oasis", "refresh-tools"}, call("refresh_tools"), nil).leaf = true
end

function change_tool_enable()
    local tool_name = luci_http.formvalue("name")
    local enable = luci_http.formvalue("enable")

    if not tool_name or tool_name == "" then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing tool name" })
        return
    end
    if enable ~= "0" and enable ~= "1" then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Invalid enable value (must be 0 or 1)" })
        return
    end

    local found = false
    uci:foreach("oasis", "tool", function(s)
        if s["name"] == tool_name then
            uci:set("oasis", s[".name"], "enable", enable)
            found = true
            return false -- break
        end
    end)
    if not found then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Tool not found" })
        return
    end
    uci:commit("oasis")
    luci_http.prepare_content("application/json")
    luci_http.write_json({ status = "OK" })
end

function add_remote_mcp_server()
    local meta_info = {}
    meta_info.name = luci_http.formvalue("name")
    meta_info.server_label = luci_http.formvalue("server_label")
    meta_info.type = luci_http.formvalue("type")
    meta_info.server_url = luci_http.formvalue("server_url")
    meta_info.require_approval = luci_http.formvalue("require_approval")

    -- allowed_tools: supports multiple values
    local allowed_tools = luci_http.formvaluetable("allowed_tools")
    if allowed_tools and next(allowed_tools) then
        meta_info.allowed_tools = {}
        for _, v in pairs(allowed_tools) do
            table.insert(meta_info.allowed_tools, v)
        end
    end

    local section = uci:add("oasis", "remote_mcp_server", meta_info.name or meta_info.server_label or "unnamed")
    for k, v in pairs(meta_info) do
        if k ~= "name" and k ~= "allowed_tools" then
            uci:set("oasis", section, k, tostring(v))
        end
    end
    if meta_info.allowed_tools then
        for _, tool in ipairs(meta_info.allowed_tools) do
            uci:add_list("oasis", section, "allowed_tools", tool)
        end
    end
    uci:commit("oasis")
    luci_http.prepare_content("application/json")
    luci_http.write_json({ status = "OK" })
end

function remove_remote_mcp_server()
    local section_name = luci_http.formvalue("name")
    if not section_name or section_name == "" then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing section name" })
        return
    end
    -- Check if the target section exists
    local found = false
    uci:foreach("oasis", "remote_mcp_server", function(s)
        if s[".name"] == section_name then
            found = true
            return false -- break
        end
    end)
    if not found then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Section not found" })
        return
    end
    -- Delete process
    local ok = uci:delete("oasis", section_name)
    if not ok then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Failed to remove remote mcp server config" })
        return
    end

    uci:commit("oasis")
    luci_http.prepare_content("application/json")
    luci_http.write_json({ status = "OK" })
end

function enable_tool()
    local tool_name = luci_http.formvalue("name")
    local server_name = luci_http.formvalue("server")
    if (not tool_name) or (not server_name) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local found = false
    uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if s["name"] == tool_name then
            -- Do not enable when conflict flag is set
            if s["conflict"] ~= "1" then
                uci:set(common.db.uci.cfg, s[".name"], "enable", "1")
                uci:commit(common.db.uci.cfg)
            end
            found = true
        end
    end)

    if not found then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Tool not found" })
        return
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json({ status = "OK" })
end

function disable_tool()
    local tool_name = luci_http.formvalue("name")
    local server_name = luci_http.formvalue("server")
    if (not tool_name) or (not server_name) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local found = false
    uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        -- Do not enable when conflict flag is set
        if s["conflict"] ~= "1" then
            uci:set(common.db.uci.cfg, s[".name"], "enable", "0")
            uci:commit(common.db.uci.cfg)
            found = true
        end
    end)

    if not found then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Tool not found" })
        return
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json({ status = "OK" })
end

function load_remote_mcp_server_info()
    local servers = {}
    uci:foreach("oasis", "remote_mcp_server", function(s)
        local entry = {}
        for k, v in pairs(s) do
            if k:sub(1,1) ~= "." then
                if type(v) == "table" then
                    entry[k] = {}
                    for _, vv in ipairs(v) do
                        table.insert(entry[k], vv)
                    end
                else
                    entry[k] = v
                end
            end
        end
        entry["name"] = s[".name"]
        table.insert(servers, entry)
    end)
    luci_http.prepare_content("application/json")
    luci_http.write_json(servers)
end

function local_tool_info()

    local tools = uci:get_all(common.db.uci.cfg)

    -- Delete unnecessary information
    tools.debug     = nil
    tools.rpc       = nil
    tools.storage   = nil
    tools.role      = nil
    tools.support   = nil
    tools.assist    = nil
    tools.rollback  = nil
    tools.console   = nil

    for key, tbl in pairs(tools) do
        if (tbl[".type"] == "service") or ( tbl[".type"] == "chat") then
            tools[key] = nil
        end
    end

    local server_list = {}
    local seen = {}

    for _, tool in pairs(tools) do
        if not seen[tool.server] then
            server_list[#server_list + 1] = tool.server
            seen[tool.server] = true
        end
    end

    local server_info = {}
    for _, name in pairs(server_list) do
            server_info[#server_info + 1] = {}
            server_info[#server_info].name = name
        if common.check_server_loaded(name) then
            server_info[#server_info].status = "loaded"
        else
            server_info[#server_info].status = "loding"
        end
    end

    local info = {}
    info.tools = tools
    info.server_info = server_info
    info.local_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")

    luci_http.prepare_content("application/json")
    luci_http.write_json(info)
end

function refresh_tools()
    sys.exec("service olt_tool restart >/dev/null 2>&1")
    sys.exec("service rpcd restart >/dev/null 2>&1")

    luci_http.prepare_content("application/json")
    luci_http.write_json({ status = "OK" })
end
