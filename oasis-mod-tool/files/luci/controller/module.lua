local sys           = require("luci.sys")
local util          = require("luci.util")
local uci           = require("luci.model.uci").cursor()
local luci_http     = require("luci.http")
local jsonc         = require("luci.jsonc")
local fs            = require("nixio.fs")
local oasis         = require("oasis.chat.apply")
local common        = require("oasis.common")
local transfer      = require("oasis.chat.transfer")
local misc          = require("oasis.chat.misc")
local datactrl      = require("oasis.chat.datactrl")
local oasis_ubus    = require("oasis.ubus.util")
local debug         = require("oasis.chat.debug")
local tool_state    = require("oasis.local.tool.state")

module("luci.controller.oasis-tool.module", package.seeall)

local manifest_dir = "/etc/oasis/tool-manifest.d/"

local function write_tool_state_result(result)
    if type(result.changed) == "boolean" then
        result.changed_bool = result.changed
        result.changed = result.changed and "1" or "0"
    end
    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

local function update_manual_tool(callback)
    local result, err = require("oasis.mode_lock").with_lock(callback)
    write_tool_state_result(result or {
        status = "NG", changed = false, code = "mode_lock_failed", error = err
    })
end

function index()

    local is_webui_support = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "webui")

    if not is_webui_support then
        return
    end

    entry({"admin", "network", "oasis", "tools"}, template("oasis/tools"), "Tools", 50).dependent=false
    entry({"admin", "network", "oasis", "change-tool-enable"}, post("change_tool_enable"), nil).leaf = true
    entry({"admin", "network", "oasis", "enable-tool"}, post("enable_tool"), nil).leaf = true
    entry({"admin", "network", "oasis", "disable-tool"}, post("disable_tool"), nil).leaf = true
    entry({"admin", "network", "oasis", "set-tool-auto"}, post("set_tool_auto"), nil).leaf = true
    entry({"admin", "network", "oasis", "add-remote-mcp-server"}, call("add_remote_mcp_server"), nil).leaf = true
    entry({"admin", "network", "oasis", "remove-remote-mcp-server"}, call("remove_remote_mcp_server"), nil).leaf = true
	entry({"admin", "network", "oasis", "local-tool-info"}, call("local_tool_info"), nil).leaf = true
	entry({"admin", "network", "oasis", "tool-manifest"}, call("tool_manifest"), nil).leaf = true
	entry({"admin", "network", "oasis", "refresh-tools"}, call("refresh_tools"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-wifi-config"}, call("load_wifi_config"), nil).leaf = true
    local update_wifi_entry = entry({"admin", "network", "oasis", "update-wifi-config"}, post("update_wifi_config"), nil)
    update_wifi_entry.leaf = true
end

function change_tool_enable()
    local tool_name = luci_http.formvalue("name")
    local server_name = luci_http.formvalue("server")
    local enable = luci_http.formvalue("enable")

    if enable ~= "0" and enable ~= "1" then
        write_tool_state_result({
            status = "NG",
            changed = false,
            code = "invalid_enable",
            error = "Invalid enable value (must be 0 or 1)"
        })
        return
    end

    update_manual_tool(function()
        local options = { manual_only = true, require_function_calling = true }
        if server_name and server_name ~= "" then
            return tool_state.set_enabled_persistent(uci, server_name, tool_name, enable, options)
        end
        return tool_state.set_enabled_by_name_persistent(uci, tool_name, enable, options)
    end)
end

local function update_tool_enable(desired)
    local tool_name = luci_http.formvalue("name")
    local server_name = luci_http.formvalue("server")

    update_manual_tool(function()
        return tool_state.set_enabled_persistent(uci, server_name, tool_name, desired,
            { manual_only = true, require_function_calling = true })
    end)
end

function enable_tool()
    update_tool_enable("1")
end

function disable_tool()
    update_tool_enable("0")
end

function set_tool_auto()
    write_tool_state_result(tool_state.set_auto_mode(uci, luci_http.formvalue("enable"),
        { require_function_calling = true }))
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
    -- Tools edits saved manual selection, independently of Agent availability
    -- and its volatile selection. Runtime callers still use snapshot().
    local registered, registry_err = tool_state.collect(uci)
    local mode = tool_state.get_mode(uci)
    local tools = {}
    for _, tool in ipairs(registered or {}) do
        tools[tool.section] = tool
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
    local err = registry_err
    info.status = err and "NG" or "OK"
    info.error = err and err.error or nil
    info.selection_mode = "manual"
    info.can_enable = require("oasis.mode").function_calling_enabled(uci)
    -- Retain mode metadata for older clients; it does not gate manual editing.
    info.auto_mode = mode and mode.auto_mode or false
    info.mode_available = mode ~= nil
    info.tools = tools
    info.server_info = server_info
    info.local_tool = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")

    luci_http.prepare_content("application/json")
    luci_http.write_json(info)
end

local function manifest_is_applied(path)
    local found = false
    uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if (s.manifest_path or "") == path then
            found = true
            return false
        end
    end)
    return found
end

local function build_manifest_summary(path, manifest)
    local servers = {}
    local seen = {}
    local tools = {}

    for _, tool in ipairs(manifest.tools or {}) do
        if type(tool) == "table" then
            local server = type(tool.server) == "string" and tool.server or ""
            local name = type(tool.name) == "string" and tool.name or ""
            if server ~= "" and not seen[server] then
                seen[server] = true
                servers[#servers + 1] = server
            end
            if server ~= "" and name ~= "" then
                local target = server .. "." .. name
                if manifest.source_type == "ubus_direct"
                    and type(tool.alias) == "string" and tool.alias ~= "" then
                    target = tool.alias .. " -> " .. target
                end
                tools[#tools + 1] = target
            end
        end
    end

    table.sort(servers)
    table.sort(tools)

    return {
        path = path,
        source_type = manifest.source_type or "",
        source_path = manifest.source_path or "",
        tool_count = #(manifest.tools or {}),
        servers = servers,
        tools = tools
    }
end

local confirmation_source_types = {
    lua_script = true,
    ucode_script = true,
    ubus_direct = true,
}

local function list_pending_manifests()
    local manifests = {}
    local files = fs.dir(manifest_dir)

    if not files then
        return manifests
    end

    for file in files do
        if type(file) == "string" and file:sub(-5) == ".json" then
            local path = manifest_dir .. file
            local raw = fs.readfile(path)
            local manifest = raw and jsonc.parse(raw) or nil

            if type(manifest) == "table"
                and confirmation_source_types[manifest.source_type] == true
                and type(manifest.tools) == "table"
                and not manifest_is_applied(path) then
                manifests[#manifests + 1] = build_manifest_summary(path, manifest)
            end
        end
    end

    table.sort(manifests, function(a, b)
        return (a.path or "") < (b.path or "")
    end)

    return manifests
end

function tool_manifest()
    local server_name = luci_http.formvalue("server")

    if (not server_name) or server_name == "" then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ status = "NG", error = "Missing server name" })
        return
    end

    local manifests = {}
    local files = fs.dir(manifest_dir)

    if files then
        for file in files do
            if type(file) == "string" and file:sub(-5) == ".json" then
                local path = manifest_dir .. file
                local raw = fs.readfile(path)
                local manifest = raw and jsonc.parse(raw) or nil

                if type(manifest) == "table" and type(manifest.tools) == "table" then
                    for _, tool in ipairs(manifest.tools) do
                        if type(tool) == "table" and tool.server == server_name then
                            manifests[#manifests + 1] = {
                                path = path,
                                source_type = manifest.source_type or "",
                                source_path = manifest.source_path or "",
                                content = raw or ""
                            }
                            break
                        end
                    end
                end
            end
        end
    end

    table.sort(manifests, function(a, b)
        return (a.path or "") < (b.path or "")
    end)

    luci_http.prepare_content("application/json")
    luci_http.write_json({
        status = "OK",
        server = server_name,
        manifests = manifests
    })
end

local function exec_service_rc(command)
    local out = sys.exec(command .. " >/dev/null 2>&1; printf '%s' $?")
    return tonumber(util.trim(out) or "") or 1
end

function refresh_tools()
    if luci_http.formvalue("confirm") ~= "1" then
        local pending = list_pending_manifests()
        if #pending > 0 then
            luci_http.prepare_content("application/json")
            luci_http.write_json({
                status = "CONFIRM_REQUIRED",
                manifests = pending
            })
            return
        end
    end

    local rc = exec_service_rc("service olt_tool restart")
    if rc ~= 0 then
        luci_http.prepare_content("application/json")
        luci_http.write_json({
            status = "NG",
            phase = "olt_tool_restart",
            error = "Failed to restart olt_tool service"
        })
        return
    end

    rc = exec_service_rc("service rpcd restart")
    if rc ~= 0 then
        luci_http.prepare_content("application/json")
        luci_http.write_json({
            status = "NG",
            phase = "rpcd_restart",
            error = "Failed to restart rpcd service"
        })
        return
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json({ status = "OK" })
end

-- Wi-Fi HTTP API. Authentication and POST/CSRF checks remain in the LuCI routes.
local wifi_config = require("oasis.local.tool.wifi_config")

local function wifi_write_json(value, status, status_message)
    if status then luci_http.status(status, status_message) end
    luci_http.prepare_content("application/json")
    luci_http.write_json(value)
end

function load_wifi_config()
    wifi_write_json(wifi_config.load(
        luci_http.formvalue("operation") or "update", luci_http.formvalue("band")))
end

function update_wifi_config()
    local content_length = tonumber(luci_http.getenv("CONTENT_LENGTH") or "0") or 0
    if content_length > 32768 then
        wifi_write_json({ ok = false, error = { code = "validation_failed",
            message = "The Wi-Fi update request is too large.", fields = {} } }, 413, "Payload Too Large")
        return
    end
    local ok, payload = pcall(luci_http.formvalue, "payload")
    if type(payload) == "string" and #payload > 24576 then
        wifi_write_json({ ok = false, error = { code = "validation_failed",
            message = "The Wi-Fi update request is too large.", fields = {} } }, 413, "Payload Too Large")
        return
    end
    local parsed, args
    if ok and type(payload) == "string" and #payload > 0 then
        parsed, args = pcall(jsonc.parse, payload)
    end
    if not parsed or type(args) ~= "table" then
        wifi_write_json({ ok = false, error = { code = "validation_failed",
            message = "A valid Wi-Fi settings payload is required.", fields = {} } }, 400, "Bad Request")
        return
    end
    wifi_write_json(wifi_config.apply(args))
end
