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
local nixio         = require("nixio")
local oasis_ubus    = require("oasis.ubus.util")
local debug         = require("oasis.chat.debug")

module("luci.controller.oasis-tool.module", package.seeall)

local manifest_dir = "/etc/oasis/tool-manifest.d/"

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
	entry({"admin", "network", "oasis", "tool-manifest"}, call("tool_manifest"), nil).leaf = true
	entry({"admin", "network", "oasis", "refresh-tools"}, call("refresh_tools"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-wifi-config"}, call("load_wifi_config"), nil).leaf = true
    local update_wifi_entry = entry({"admin", "network", "oasis", "update-wifi-config"}, post("update_wifi_config"), nil)
    update_wifi_entry.leaf = true
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

local function update_tool_enable(desired)
    local tool_name = luci_http.formvalue("name")
    local server_name = luci_http.formvalue("server")

    if (not tool_name) or tool_name == "" or (not server_name) or server_name == "" then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ status = "NG", error = "Missing params" })
        return
    end

    local match_count = 0
    local target_section = nil
    local current_enable = nil
    local conflicted = false
    local changed = false

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if (server_name == s["server"]) and (tool_name == s["name"]) then
            match_count = match_count + 1
            target_section = s[".name"]
            current_enable = s["enable"] or "0"
            conflicted = (s["conflict"] == "1")
        end
    end)

    if match_count == 0 then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ status = "NG", error = "Tool not found" })
        return
    end

    if match_count > 1 then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ status = "NG", error = "Duplicate tool sections found" })
        return
    end

    if conflicted then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ status = "NG", error = "Tool is conflicted" })
        return
    end

    if current_enable ~= desired then
        uci:set(common.db.uci.cfg, target_section, "enable", desired)
        uci:commit(common.db.uci.cfg)
        changed = true
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json({
        status = "OK",
        changed = changed and "1" or "0"
    })
end

function enable_tool()
    update_tool_enable("1")
end

function disable_tool()
    update_tool_enable("0")
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

    for _, tool in ipairs(manifest.tools or {}) do
        if type(tool) == "table" then
            local server = tool.server or ""
            if server ~= "" and not seen[server] then
                seen[server] = true
                servers[#servers + 1] = server
            end
        end
    end

    table.sort(servers)

    return {
        path = path,
        source_type = manifest.source_type or "",
        source_path = manifest.source_path or "",
        tool_count = #(manifest.tools or {}),
        servers = servers
    }
end

local function list_pending_manual_manifests()
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
                and manifest.source_type == "manual"
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
        local pending = list_pending_manual_manifests()
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

-- Wi-Fi configuration API -------------------------------------------------
--
-- Tool calls only request this form.  The authenticated LuCI API below owns
-- all read/write access so SSIDs and passphrases never pass through an AI
-- provider, the tool protocol, or Oasis chat history.

local WIFI_CONFIG = "wireless"
local WIFI_CONFIG_PATH = "/etc/config/wireless"
local WIFI_LOCK_PATH = "/var/lock/oasis-wifi-config.lock"
local WIFI_MAX_REQUEST = 32768
local WIFI_MAX_PAYLOAD = 24576
local WIFI_MAX_INTERFACES = 32

local WIFI_ENCRYPTIONS = {
    none = true,
    psk2 = true,
    ["psk2+ccmp"] = true,
    sae = true,
    ["sae-mixed"] = true
}

local WIFI_BANDS = {
    ["2g"] = { label = "2.4 GHz", value = "2G" },
    ["5g"] = { label = "5 GHz", value = "5G" }
}

local WIFI_SUPPORTED_BANDS = {
    ["2G"] = true,
    ["5G"] = true
}

local WIFI_ENCRYPTION_OPTIONS = {
    { value = "none", label = "Open (no password)" },
    { value = "psk2", label = "WPA2 Personal" },
    { value = "psk2+ccmp", label = "WPA2 Personal (CCMP)" },
    { value = "sae", label = "WPA3 Personal" },
    { value = "sae-mixed", label = "WPA2/WPA3 Personal" }
}

local WIFI_BAND_ENCRYPTIONS = {
    ["2G"] = WIFI_ENCRYPTIONS,
    ["5G"] = WIFI_ENCRYPTIONS
}

local function wifi_write_json(value, status, status_message)
    if status then
        luci_http.status(status, status_message)
    end
    luci_http.prepare_content("application/json")
    luci_http.write_json(value)
end

local function wifi_error(code, message, fields)
    return {
        ok = false,
        error = {
            code = code,
            message = message,
            fields = fields or {}
        }
    }
end

local function wifi_file_revision()
    local stat = fs.stat(WIFI_CONFIG_PATH)
    if not stat or stat.type ~= "reg" then
        return nil
    end
    return string.format(
        "wifi:%s:%s:%s:%s",
        tostring(stat.mtime or 0),
        tostring(stat.ctime or 0),
        tostring(stat.ino or 0),
        tostring(stat.size or 0)
    )
end

local function wifi_band_label(raw_band, hwmode)
    local definition = WIFI_BANDS[raw_band]
    if definition then
        return definition.label, definition.value
    end

    -- Older OpenWrt configurations may use hwmode instead of band.
    if hwmode == "11b" or hwmode == "11g" then
        return "2.4 GHz", "2G"
    elseif hwmode == "11a" then
        return "5 GHz", "5G"
    end
    return "Unknown band", nil
end

local function wifi_supported_band(value)
    return WIFI_SUPPORTED_BANDS[value] == true
end

local function wifi_encryption_supported(band, encryption)
    local allowed = WIFI_BAND_ENCRYPTIONS[band]
    return type(encryption) == "string" and allowed and allowed[encryption] == true
end

local function wifi_encryption_options(_band)
    return WIFI_ENCRYPTION_OPTIONS
end

local function wifi_is_text(value, maximum)
    return type(value) == "string"
        and #value > 0
        and #value <= maximum
        and value:find("[%z\1-\31\127]") == nil
end

local function wifi_is_section_name(value)
    return type(value) == "string"
        and #value > 0
        and #value <= 128
        and value:match("^[A-Za-z0-9_]+$") ~= nil
end

local function wifi_is_dense_array(value)
    if type(value) ~= "table" then
        return false
    end
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return false
        end
        count = count + 1
    end
    return #value == count
end

local function wifi_reject_unknown(value, allowed, path, errors)
    if type(value) ~= "table" then
        return
    end
    for key in pairs(value) do
        if allowed[key] ~= true then
            errors[path] = "One or more unsupported fields were supplied."
            return
        end
    end
end

local function wifi_valid_passphrase(value, encryption)
    if type(value) ~= "string" or value:find("[%z\1-\31\127]") then
        return false
    end
    if #value >= 8 and #value <= 63 then
        return true
    end
    return (encryption == "psk2" or encryption == "psk2+ccmp")
        and #value == 64
        and value:match("^[0-9A-Fa-f]+$") ~= nil
end

local function wifi_read_state()
    local revision = wifi_file_revision()
    if not revision then
        return nil, nil
    end

    local state = {
        devices = {},
        device_map = {},
        interfaces = {},
        interface_map = {}
    }

    uci:foreach(WIFI_CONFIG, "wifi-device", function(section)
        local name = section[".name"]
        local raw_band = tostring(section.band or "")
        local label, band = wifi_band_label(raw_band, tostring(section.hwmode or ""))
        local item = {
            section = name,
            band = band,
            label = label,
            raw_band = raw_band,
            disabled = section.disabled,
            raw = section
        }
        state.devices[#state.devices + 1] = item
        state.device_map[name] = item
    end)

    uci:foreach(WIFI_CONFIG, "wifi-iface", function(section)
        local name = section[".name"]
        local configured_device = section.device
        local device = type(configured_device) == "string"
            and state.device_map[configured_device] or nil
        if tostring(section.mode or "") == "ap"
            and device and wifi_supported_band(device.band) then
            local encryption = tostring(section.encryption or "none")
            local item = {
                section = name,
                device = device.section,
                band = device.band,
                band_label = device.label,
                ssid = tostring(section.ssid or ""),
                encryption = encryption,
                encryption_supported = wifi_encryption_supported(device.band, encryption),
                key_configured = type(section.key) == "string" and #section.key > 0,
                disabled = section.disabled,
                raw = section,
                device_raw = device.raw
            }
            state.interfaces[#state.interfaces + 1] = item
            state.interface_map[name] = item
        end
    end)

    table.sort(state.devices, function(left, right)
        return (left.section or "") < (right.section or "")
    end)
    table.sort(state.interfaces, function(left, right)
        return (left.section or "") < (right.section or "")
    end)

    return state, revision
end

local function wifi_snapshot(state, revision, operation, band)
    local devices = {}
    local interfaces = {}

    for _, device in ipairs(state.devices) do
        if wifi_supported_band(device.band) then
            if operation ~= "add" or device.band == band then
                devices[#devices + 1] = {
                    section = device.section,
                    band = device.band,
                    label = device.label
                }
            end
        end
    end

    if operation == "update" or operation == "delete" then
        for _, interface in ipairs(state.interfaces) do
            interfaces[#interfaces + 1] = {
                section = interface.section,
                device = interface.device,
                band = interface.band,
                band_label = interface.band_label,
                ssid = interface.ssid,
                encryption = interface.encryption,
                encryption_supported = interface.encryption_supported,
                key_configured = interface.key_configured,
                encryption_options = wifi_encryption_options(interface.band)
            }
        end
    end

    return {
        ok = true,
        schema_version = 1,
        revision = revision,
        operation = operation,
        band = band,
        devices = devices,
        interfaces = interfaces,
        encryption_options = wifi_encryption_options(band)
    }
end

function load_wifi_config()
    local operation = luci_http.formvalue("operation") or "update"
    local band = luci_http.formvalue("band")
    if operation ~= "update" and operation ~= "add" and operation ~= "delete" then
        wifi_write_json(wifi_error(
            "validation_failed", "The Wi-Fi form request is invalid."
        ), 400, "Bad Request")
        return
    end
    if operation == "add" and not wifi_supported_band(band) then
        wifi_write_json(wifi_error(
            "validation_failed", "Select a supported Wi-Fi band."
        ), 400, "Bad Request")
        return
    end

    local state, revision = wifi_read_state()
    if not state then
        wifi_write_json(wifi_error(
            "read_failed", "The wireless configuration could not be read."
        ), 500, "Internal Server Error")
        return
    end
    wifi_write_json(wifi_snapshot(state, revision, operation, band))
end

local function wifi_add_error(errors, path, message)
    if errors[path] == nil then
        errors[path] = message
    end
end

local function wifi_normalize_update(args, state, errors)
    wifi_reject_unknown(args, {
        revision = true,
        operation = true,
        interfaces = true
    }, "payload", errors)

    if args.operation ~= "update" then
        wifi_add_error(errors, "operation", "Invalid Wi-Fi configuration operation.")
    end
    if not wifi_is_dense_array(args.interfaces)
        or #args.interfaces == 0
        or #args.interfaces > WIFI_MAX_INTERFACES then
        wifi_add_error(errors, "interfaces", "Provide one or more Wi-Fi access point settings.")
        return nil
    end

    local normalized = { operation = "update", interfaces = {} }
    local seen = {}
    for index, value in ipairs(args.interfaces) do
        local prefix = "interfaces." .. tostring(index)
        if type(value) ~= "table" or #value ~= 0 then
            wifi_add_error(errors, prefix, "The Wi-Fi settings entry is invalid.")
        else
            wifi_reject_unknown(value, {
                section = true,
                ssid = true,
                encryption = true,
                passphrase = true
            }, prefix, errors)

            local current = nil
            if wifi_is_section_name(value.section) then
                current = state.interface_map[value.section]
            end
            if not current then
                wifi_add_error(errors, prefix .. ".section", "The Wi-Fi access point no longer exists.")
            elseif seen[value.section] then
                wifi_add_error(errors, prefix .. ".section", "Each Wi-Fi access point can be updated only once.")
            else
                seen[value.section] = true
            end
            if not wifi_is_text(value.ssid, 32) then
                wifi_add_error(errors, prefix .. ".ssid", "SSID must contain 1 to 32 bytes and no control characters.")
            end
            if not current or not wifi_encryption_supported(current.band, value.encryption) then
                wifi_add_error(errors, prefix .. ".encryption", "Select a supported encryption mode.")
            end
            if type(value.passphrase) ~= "string" or #value.passphrase > 64 then
                wifi_add_error(errors, prefix .. ".passphrase", "Passphrase format is invalid.")
            elseif value.encryption == "none" and value.passphrase ~= "" then
                wifi_add_error(errors, prefix .. ".passphrase", "An open Wi-Fi network cannot have a passphrase.")
            elseif value.encryption ~= "none" and #value.passphrase > 0
                and not wifi_valid_passphrase(value.passphrase, value.encryption) then
                wifi_add_error(errors, prefix .. ".passphrase", "Passphrase must be 8 to 63 characters. WPA2 also accepts a 64-character hexadecimal key.")
            elseif current and value.encryption ~= "none" and #value.passphrase == 0
                and (value.encryption ~= current.encryption or not current.key_configured) then
                wifi_add_error(errors, prefix .. ".passphrase", "Enter a passphrase when changing encryption or configuring an unset key.")
            end

            normalized.interfaces[#normalized.interfaces + 1] = {
                section = value.section,
                ssid = value.ssid,
                encryption = value.encryption,
                passphrase = value.passphrase
            }
        end
    end
    return normalized
end

local function wifi_normalize_add(args, state, errors)
    wifi_reject_unknown(args, {
        revision = true,
        operation = true,
        band = true,
        device = true,
        ssid = true,
        encryption = true,
        passphrase = true
    }, "payload", errors)

    if args.operation ~= "add" then
        wifi_add_error(errors, "operation", "Invalid Wi-Fi configuration operation.")
    end
    if not wifi_supported_band(args.band) then
        wifi_add_error(errors, "band", "Select a supported Wi-Fi band.")
    end
    local device = nil
    if wifi_is_section_name(args.device) then
        device = state.device_map[args.device]
    end
    if not device or device.band ~= args.band then
        wifi_add_error(errors, "device", "Select an available radio for the requested Wi-Fi band.")
    end
    if not wifi_is_text(args.ssid, 32) then
        wifi_add_error(errors, "ssid", "SSID must contain 1 to 32 bytes and no control characters.")
    end
    if not wifi_encryption_supported(args.band, args.encryption) then
        wifi_add_error(errors, "encryption", "Select a supported encryption mode.")
    end
    if type(args.passphrase) ~= "string" or #args.passphrase > 64 then
        wifi_add_error(errors, "passphrase", "Passphrase format is invalid.")
    elseif args.encryption == "none" and args.passphrase ~= "" then
        wifi_add_error(errors, "passphrase", "An open Wi-Fi network cannot have a passphrase.")
    elseif args.encryption ~= "none" and not wifi_valid_passphrase(args.passphrase, args.encryption) then
        wifi_add_error(errors, "passphrase", "Passphrase must be 8 to 63 characters. WPA2 also accepts a 64-character hexadecimal key.")
    end
    if not uci:get_all("network", "lan") then
        wifi_add_error(errors, "network", "The lan network configuration is unavailable.")
    end

    return {
        operation = "add",
        band = args.band,
        device = args.device,
        ssid = args.ssid,
        encryption = args.encryption,
        passphrase = args.passphrase
    }
end

local function wifi_normalize_delete(args, state, errors)
    wifi_reject_unknown(args, {
        revision = true,
        operation = true,
        section = true
    }, "payload", errors)

    if args.operation ~= "delete" then
        wifi_add_error(errors, "operation", "Invalid Wi-Fi configuration operation.")
    end

    local target = nil
    if wifi_is_section_name(args.section) then
        target = state.interface_map[args.section]
    end
    if not target then
        wifi_add_error(errors, "section", "The Wi-Fi access point no longer exists.")
    end

    return {
        operation = "delete",
        section = args.section
    }
end

local function wifi_enable_target(section, current, device)
    if current and current.raw and current.raw.disabled ~= nil then
        uci:set(WIFI_CONFIG, section, "disabled", "0")
    end
    if device and device.raw and device.raw.disabled ~= nil then
        uci:set(WIFI_CONFIG, device.section, "disabled", "0")
    end
end

local function wifi_remove_keys(section)
    uci:delete(WIFI_CONFIG, section, "key")
    uci:delete(WIFI_CONFIG, section, "key1")
    uci:delete(WIFI_CONFIG, section, "key2")
    uci:delete(WIFI_CONFIG, section, "key3")
    uci:delete(WIFI_CONFIG, section, "key4")
end

local function wifi_apply_update(normalized, state)
    if normalized.operation == "update" then
        for _, value in ipairs(normalized.interfaces) do
            local current = state.interface_map[value.section]
            local device = state.device_map[current.device]
            uci:set(WIFI_CONFIG, value.section, "ssid", value.ssid)
            uci:set(WIFI_CONFIG, value.section, "encryption", value.encryption)
            if value.encryption == "none" then
                wifi_remove_keys(value.section)
            elseif #value.passphrase > 0 then
                uci:set(WIFI_CONFIG, value.section, "key", value.passphrase)
            end
            wifi_enable_target(value.section, current, device)
        end
    elseif normalized.operation == "delete" then
        if uci:delete(WIFI_CONFIG, normalized.section) == false then
            return nil
        end
    else
        local section = uci:section(WIFI_CONFIG, "wifi-iface")
        if not section then
            return nil
        end
        uci:set(WIFI_CONFIG, section, "device", normalized.device)
        uci:set(WIFI_CONFIG, section, "network", "lan")
        uci:set(WIFI_CONFIG, section, "mode", "ap")
        uci:set(WIFI_CONFIG, section, "ssid", normalized.ssid)
        uci:set(WIFI_CONFIG, section, "encryption", normalized.encryption)
        if normalized.encryption ~= "none" then
            uci:set(WIFI_CONFIG, section, "key", normalized.passphrase)
        end
        local device = state.device_map[normalized.device]
        wifi_enable_target(section, nil, device)
    end

    if uci:commit(WIFI_CONFIG) == false then
        return nil
    end
    return true
end

local function wifi_acquire_lock()
    local lock = nixio.open(WIFI_LOCK_PATH, "a", "0600")
    if not lock then
        return nil
    end
    lock:seek(0, "set")
    if not lock:lock("tlock") then
        lock:close()
        return nil
    end
    return lock
end

local function wifi_release_lock(lock)
    if not lock then
        return
    end
    lock:seek(0, "set")
    lock:lock("ulock")
    lock:close()
end

local function wifi_update_locked(args)
    local state, current_revision = wifi_read_state()
    if not state or not current_revision then
        return wifi_error("read_failed", "The wireless configuration could not be read."), 500, "Internal Server Error"
    end
    if args.revision ~= current_revision then
        return wifi_error(
            "revision_conflict",
            "The wireless settings changed after this form was opened. Reload the form before saving again."
        ), 409, "Conflict"
    end

    local errors = {}
    local normalized
    if args.operation == "update" then
        normalized = wifi_normalize_update(args, state, errors)
    elseif args.operation == "add" then
        normalized = wifi_normalize_add(args, state, errors)
    elseif args.operation == "delete" then
        normalized = wifi_normalize_delete(args, state, errors)
    else
        wifi_add_error(errors, "operation", "Invalid Wi-Fi configuration operation.")
    end
    if next(errors) ~= nil then
        return wifi_error("validation_failed", "One or more Wi-Fi settings are invalid.", errors), 400, "Bad Request"
    end

    local latest_state, latest_revision = wifi_read_state()
    if not latest_state or latest_revision ~= current_revision then
        return wifi_error(
            "revision_conflict",
            "The wireless settings changed while the update was being prepared. Reload the form before saving again."
        ), 409, "Conflict"
    end

    if not wifi_apply_update(normalized, latest_state) then
        uci:revert(WIFI_CONFIG)
        return wifi_error("write_failed", "The Wi-Fi settings could not be saved."), 500, "Internal Server Error"
    end

    -- This command has no user-controlled part.  All user input is written
    -- through the UCI cursor above, so it cannot become shell syntax.
    local reload_status = sys.exec(
        "/sbin/wifi reload >/dev/null 2>&1; printf '%s' $?"
    )
    if tonumber(util.trim(reload_status or "")) ~= 0 then
        return {
            ok = false,
            saved = true,
            error = {
                code = "reload_failed",
                message = "The Wi-Fi settings were saved, but Wi-Fi reload failed. Verify the router from a wired connection.",
                fields = {}
            }
        }, 500, "Internal Server Error"
    end

    local updated_state, updated_revision = wifi_read_state()
    if not updated_state or not updated_revision then
        return wifi_error("read_failed", "The Wi-Fi settings were saved but could not be reloaded."), 500, "Internal Server Error"
    end
    local response = wifi_snapshot(updated_state, updated_revision, normalized.operation, normalized.band)
    response.ok = true
    response.saved = true
    return response
end

function update_wifi_config()
    local content_length = tonumber(luci_http.getenv("CONTENT_LENGTH") or "0") or 0
    if content_length > WIFI_MAX_REQUEST then
        wifi_write_json(wifi_error(
            "validation_failed", "The Wi-Fi update request is too large."
        ), 413, "Payload Too Large")
        return
    end

    local payload_ok, payload = pcall(luci_http.formvalue, "payload")
    if not payload_ok or type(payload) ~= "string"
        or #payload == 0 or #payload > WIFI_MAX_PAYLOAD then
        wifi_write_json(wifi_error(
            "validation_failed", "A valid Wi-Fi settings payload is required."
        ), 400, "Bad Request")
        return
    end

    local parse_ok, args = pcall(jsonc.parse, payload)
    if not parse_ok or type(args) ~= "table"
        or type(args.revision) ~= "string" or #args.revision == 0
        or #args.revision > 128 or args.revision:find("[%z\1-\31\127]") then
        wifi_write_json(wifi_error(
            "validation_failed", "The Wi-Fi update request is invalid."
        ), 400, "Bad Request")
        return
    end

    local lock_ok, lock = pcall(wifi_acquire_lock)
    if not lock_ok then
        wifi_write_json(wifi_error(
            "write_failed", "The Wi-Fi update lock could not be acquired."
        ), 500, "Internal Server Error")
        return
    end
    if not lock then
        wifi_write_json(wifi_error(
            "write_failed", "The Wi-Fi settings are currently being updated. Try again shortly."
        ), 503, "Service Unavailable")
        return
    end

    local ok, body, status, status_message = pcall(wifi_update_locked, args)
    if not ok then
        pcall(function()
            uci:revert(WIFI_CONFIG)
        end)
        body = wifi_error("write_failed", "An unexpected error prevented the Wi-Fi update.")
        status = 500
        status_message = "Internal Server Error"
    end
    wifi_release_lock(lock)
    wifi_write_json(body, status, status_message)
end
