local uci       = require("luci.model.uci").cursor()
local common    = require("oasis.common")
local misc      = require("oasis.chat.misc")
local mgr       = require("oasis.local.tool.package.manager")
local debug     = require("oasis.chat.debug")
local jsonc     = require("luci.jsonc")
local sys       = require("luci.sys")
local fs        = require("nixio.fs")
local tool_state = require("oasis.local.tool.state")
local uci_transaction = require("oasis.local.tool.uci_transaction")

local M = {}

local lua_ubus_server_app_dir = "/usr/libexec/rpcd/"
local ucode_ubus_server_app_dir = "/usr/share/rpcd/ucode/"
local manifest_dir = "/etc/oasis/tool-manifest.d/"
local control_tool_server = "oasis.tool.manager"
local listup_server_candidate
local check_tool_name_conflict
local sort_tool_defs

-- Quote dynamic paths before passing them to shell commands.
local function shell_quote(s)
    s = tostring(s or "")
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function is_regular_file(path)
    local st = fs.stat(path)
    return st and st.type == "reg"
end

local function is_oasis_tool_server(path)
    local content = fs.readfile(path)
    if not content then
        return false
    end
    -- Only scripts that use the Oasis local tool server are scan targets.
    return content:find("oasis.local.tool.server", 1, true) ~= nil
end

local function resolve_manifest_script_path(script_path)
    local runtime_path = tostring(script_path or "")
    local mapped = runtime_path:match("/files(/usr/libexec/rpcd/.+)$")
        or runtime_path:match("/files(/usr/share/rpcd/ucode/.+)$")

    if mapped then
        return mapped
    end

    return runtime_path
end

local function detect_script_type(script_path)
    local path = tostring(script_path or "")
    if path:sub(-3) == ".uc" or path:find("/usr/share/rpcd/ucode/", 1, true) then
        return "ucode"
    end

    return "lua"
end

local function source_type_from_script_kind(script_kind)
    if script_kind == "lua" then
        return "lua_script"
    elseif script_kind == "ucode" then
        return "ucode_script"
    elseif script_kind == "ubus_direct" then
        return "ubus_direct"
    end

    return nil
end

local function script_kind_from_source_type(source_type)
    if source_type == "lua_script" then
        return "lua"
    elseif source_type == "ucode_script" then
        return "ucode"
    elseif source_type == "ubus_direct" then
        return "ubus_direct"
    end

    return nil
end

local ubus_call = function(path, method, param, timeout)

    local result, err = common.ubus_call(path, method, param, timeout)

    if not result then
        return { error = err or "Failed to execute ubus call" }
    end

    return result
end

local function build_param_lists(args, args_desc, type_resolver)
    local params = {}
    local required_list = {}
    local property_list = {}

    if type(args) ~= "table" then
        return required_list, property_list
    end

    for param, _ in pairs(args) do
        params[#params + 1] = param
    end
    table.sort(params)

    for i, param in ipairs(params) do
        required_list[#required_list + 1] = param

        local desc = ""
        if type(args_desc) == "table" then
            desc = args_desc[i] or ""
        end

        local typ = type_resolver(args[param])
        property_list[#property_list + 1] = string.format("%s:%s:%s", param, typ, desc)
    end

    return required_list, property_list
end

local function build_tool_def(script, server, name, desc, exec_msg, download_msg, timeout, required, property)
    return {
        name = name,
        script = script,
        server = server,
        type = "function",
        description = desc or "",
        execution_message = exec_msg or "",
        download_message = download_msg or "",
        timeout = timeout or "",
        conflict = "0",
        required = required or {},
        property = property or {},
        additionalProperties = "0",
    }
end

local function scan_lua_script_defs(script_path, server_name)
    if not is_regular_file(script_path) then
        return nil, "lua tool script not found: " .. script_path
    end

    if not is_oasis_tool_server(script_path) then
        return nil, "not an oasis lua tool script: " .. script_path
    end

    local meta_cmd
    if fs.access(script_path, "x") then
        meta_cmd = shell_quote(script_path) .. " meta 2>/dev/null"
    elseif misc.check_file_exist("/usr/bin/lua") then
        meta_cmd = "lua " .. shell_quote(script_path) .. " meta 2>/dev/null"
    else
        return nil, "lua not installed"
    end

    local meta = sys.exec(meta_cmd)
    local data = jsonc.parse(meta)
    if not data then
        return nil, "invalid lua tool metadata: " .. script_path
    end

    local type_map = { a_string = "string", integer = "number", boolean = "boolean", number = "number", string = "string" }
    local defs = {}

    for tool_name, tool in pairs(data) do
        local required, property = build_param_lists(tool.args, tool.args_desc, function(v)
            return type_map[v] or "string"
        end)

        defs[#defs + 1] = build_tool_def(
            "lua",
            server_name,
            tool_name,
            tool.tool_desc,
            tool.exec_msg,
            tool.download_msg,
            tool.timeout,
            required,
            property
        )
    end

    return defs, nil
end

local function scan_ucode_script_defs(script_path)
    if not is_regular_file(script_path) then
        return nil, "ucode tool script not found: " .. script_path
    end

    if not is_oasis_tool_server(script_path) then
        return nil, "not an oasis ucode tool script: " .. script_path
    end

    if not misc.check_file_exist("/usr/bin/ucode") then
        return nil, "ucode not installed"
    end

    local meta = sys.exec("ucode " .. shell_quote(script_path) .. " 2>/dev/null")
    local data = jsonc.parse(meta)
    if not data then
        return nil, "invalid ucode tool metadata: " .. script_path
    end

    local function detect_type(v)
        local t = type(v)
        if t == "number" then return "number"
        elseif t == "boolean" then return "boolean"
        elseif t == "string" then return "string"
        else return "string" end
    end

    local defs = {}

    for server, tbl in pairs(data) do
        for tool, def in pairs(tbl) do
            local required, property = build_param_lists(def.args, def.args_desc, detect_type)
            defs[#defs + 1] = build_tool_def(
                "ucode",
                server,
                tool,
                def.tool_desc,
                def.exec_msg,
                def.download_msg,
                def.timeout,
                required,
                property
            )
        end
    end

    return defs, nil
end

local function scan_lua_server_defs(server_name)
    local server_path = lua_ubus_server_app_dir .. server_name

    if not is_regular_file(server_path) then
        debug:log("oasis.log", "scan_lua_server_defs", "skip non-regular file: " .. server_name)
        return {}, nil
    end

    if not fs.access(server_path, "x") then
        debug:log("oasis.log", "scan_lua_server_defs", "skip non-executable file: " .. server_name)
        return {}, nil
    end

    return scan_lua_script_defs(server_path, server_name)
end

local function scan_ucode_server_defs(server_name)
    local server_path = ucode_ubus_server_app_dir .. server_name

    if not is_regular_file(server_path) then
        debug:log("oasis.log", "scan_ucode_server_defs", "skip non-regular file: " .. server_name)
        return {}, nil
    end

    if not is_oasis_tool_server(server_path) then
        debug:log("oasis.log", "scan_ucode_server_defs", "skip non-oasis server file: " .. server_name)
        return {}, nil
    end

    return scan_ucode_script_defs(server_path)
end

local function to_list(v)
    if v == nil then return {} end
    if type(v) == "table" then return v end
    return { v }
end

local function normalize_tool_def(def)
    local required = to_list(def.required)
    local property = to_list(def.property)
    table.sort(required)
    table.sort(property)
    return {
        name = def.name or "",
        script = def.script or "",
        server = def.server or "",
        type = def.type or "function",
        description = def.description or "",
        additionalProperties = def.additionalProperties or "0",
        required = required,
        property = property,
    }
end

local function make_tool_key(def)
    return string.format("%s|%s|%s", def.script or "", def.server or "", def.name or "")
end

local function defs_equal(a, b)
    if not a or not b then return false end
    if a.name ~= b.name then return false end
    if a.script ~= b.script then return false end
    if a.server ~= b.server then return false end
    if a.type ~= b.type then return false end
    if a.description ~= b.description then return false end
    if a.additionalProperties ~= b.additionalProperties then return false end
    if #a.required ~= #b.required then return false end
    for i = 1, #a.required do
        if a.required[i] ~= b.required[i] then return false end
    end
    if #a.property ~= #b.property then return false end
    for i = 1, #a.property do
        if a.property[i] ~= b.property[i] then return false end
    end
    return true
end

local function append_unique_tool_defs(defs, seen, incoming_defs)
    for _, def in ipairs(incoming_defs or {}) do
        local normalized = normalize_tool_def(def)
        local key = make_tool_key(normalized)
        if seen[key] then
            return nil, "duplicate tool definition: " .. key
        end
        seen[key] = true
        defs[#defs + 1] = def
    end
    return true, nil
end

local function basename(path)
    return tostring(path or ""):match("([^/]+)$") or ""
end

local function property_list_to_manifest_properties(property_list)
    local properties = {}
    for _, prop in ipairs(to_list(property_list)) do
        local name, typ, desc = tostring(prop):match("^([^:]+):([^:]+):(.*)$")
        if name and typ then
            properties[#properties + 1] = {
                name = name,
                type = typ,
                description = desc or "",
            }
        end
    end
    table.sort(properties, function(a, b)
        if a.name == b.name then
            return a.type < b.type
        end
        return a.name < b.name
    end)
    return properties
end

local function manifest_properties_to_property_list(properties)
    local property_list = {}
    if type(properties) ~= "table" then
        return property_list, nil
    end

    for _, prop in ipairs(properties) do
        if type(prop) ~= "table" then
            return nil, "invalid property entry"
        end

        local name = prop.name or ""
        local typ = prop.type or ""
        local desc = prop.description or ""
        if type(name) ~= "string" or name == "" then
            return nil, "invalid property name"
        end
        if type(typ) ~= "string" or typ == "" then
            return nil, "invalid property type"
        end
        if type(desc) ~= "string" then
            return nil, "invalid property description"
        end

        property_list[#property_list + 1] = string.format("%s:%s:%s", name, typ, desc)
    end

    table.sort(property_list)
    return property_list, nil
end

local function build_manifest(script_kind, script_path, defs)
    local source_type = source_type_from_script_kind(script_kind)
    local manifest = {
        version = 1,
        source_type = source_type,
        source_path = script_path,
        tools = {},
    }

    for _, def in ipairs(defs or {}) do
        local normalized = normalize_tool_def(def)
        manifest.tools[#manifest.tools + 1] = {
            server = normalized.server,
            name = normalized.name,
            type = normalized.type,
            description = normalized.description,
            execution_message = def.execution_message or "",
            download_message = def.download_message or "",
            timeout = def.timeout or "",
            required = normalized.required,
            properties = property_list_to_manifest_properties(normalized.property),
            additional_properties = (normalized.additionalProperties == "1"),
        }
    end

    table.sort(manifest.tools, function(a, b)
        local ka = string.format("%s|%s", a.server or "", a.name or "")
        local kb = string.format("%s|%s", b.server or "", b.name or "")
        return ka < kb
    end)

    return manifest
end

local function manifest_filename(script_type, script_path)
    if script_type == "lua_script" then
        script_type = "lua"
    elseif script_type == "ucode_script" then
        script_type = "ucode"
    end
    local base = basename(script_path)
    if base == "" then
        base = "unknown"
    end
    return string.format("%s.%s.json", script_type or "unknown", base)
end

local function write_manifest_file(manifest)
    if not fs.stat(manifest_dir) and not fs.mkdirr(manifest_dir) then
        return false, "failed to create manifest dir"
    end

    local path = manifest_dir .. manifest_filename(manifest.source_type, manifest.source_path)
    local content = jsonc.stringify(manifest, true)
    if not content then
        return false, "failed to stringify manifest"
    end

    if not fs.writefile(path, content .. "\n") then
        return false, "failed to write manifest: " .. path
    end

    return true, path
end

local function manifest_tool_to_def(script_kind, tool)
    if type(tool) ~= "table" then
        return nil, "tool entry must be an object"
    end

    local server = tool.server or ""
    local name = tool.name or ""
    local type_name = tool.type or "function"
    local description = tool.description or ""
    local execution_message = tool.execution_message or ""
    local download_message = tool.download_message or ""
    local timeout = tool.timeout or ""
    local additional_properties = tool.additional_properties
    local required = {}

    if type(server) ~= "string" or server == "" then
        return nil, "missing tool server"
    end
    if type(name) ~= "string" or name == "" then
        return nil, "missing tool name"
    end
    if type(type_name) ~= "string" or type_name == "" then
        return nil, "missing tool type"
    end
    if type(description) ~= "string" or description == "" then
        return nil, "missing tool description"
    end
    if type(execution_message) ~= "string" then
        return nil, "invalid execution_message"
    end
    if type(download_message) ~= "string" then
        return nil, "invalid download_message"
    end
    if type(timeout) ~= "string" and type(timeout) ~= "number" then
        return nil, "invalid timeout"
    end
    if additional_properties ~= nil and type(additional_properties) ~= "boolean" then
        return nil, "invalid additional_properties"
    end

    if tool.required ~= nil then
        if type(tool.required) ~= "table" then
            return nil, "invalid required list"
        end
        for _, item in ipairs(tool.required) do
            if type(item) ~= "string" or item == "" then
                return nil, "invalid required entry"
            end
            required[#required + 1] = item
        end
    end
    table.sort(required)

    local property_list, property_err = manifest_properties_to_property_list(tool.properties)
    if not property_list then
        return nil, property_err or "invalid properties"
    end
    local def = build_tool_def(
        script_kind,
        server,
        name,
        description,
        execution_message,
        download_message,
        tostring(timeout or ""),
        required,
        property_list
    )
    def.type = type_name
    def.additionalProperties = (additional_properties == true) and "1" or "0"

    return def, nil
end

local function load_manifest_file(path, opts)
    local raw = fs.readfile(path)
    if not raw then
        return nil, nil, "failed to read manifest: " .. path
    end

    local manifest = jsonc.parse(raw)
    if type(manifest) ~= "table" then
        return nil, nil, "invalid manifest json: " .. path
    end

    if manifest.version ~= 1 then
        return nil, nil, "unsupported manifest version: " .. path
    end
    if manifest.source_type ~= "lua_script" and manifest.source_type ~= "ucode_script" and manifest.source_type ~= "ubus_direct" then
        return nil, nil, "invalid manifest source_type: " .. path
    end
    if type(manifest.tools) ~= "table" then
        return nil, nil, "invalid manifest tools: " .. path
    end

    local source_path = manifest.source_path
    if source_path ~= nil then
        if type(source_path) ~= "string" then
            return nil, nil, "invalid manifest source_path: " .. path
        end
        if source_path == "" then
            source_path = nil
        end
    end

    if manifest.source_type ~= "ubus_direct" and not source_path then
        return nil, nil, "invalid manifest source_path: " .. path
    end

    if manifest.source_type ~= "ubus_direct" and not is_regular_file(source_path) then
        if opts and opts.strict then
            return nil, nil, "stale manifest target: " .. source_path
        end
        debug:log("oasis.log", "load_manifest_file", "skip stale manifest: " .. path)
        return {}, nil, nil
    end

    if manifest.source_type == "lua_script" and not fs.access(source_path, "x") then
        if opts and opts.strict then
            return nil, nil, "non-executable lua manifest target: " .. source_path
        end
        debug:log("oasis.log", "load_manifest_file", "skip non-executable lua manifest target: " .. path)
        return {}, nil, nil
    end

    local script_kind = script_kind_from_source_type(manifest.source_type)
    if not script_kind then
        return nil, nil, "invalid manifest source_type: " .. path
    end

    local defs = {}
    local seen = {}
    for i, tool in ipairs(manifest.tools) do
        local def, err = manifest_tool_to_def(script_kind, tool)
        if not def then
            return nil, nil, string.format("invalid manifest tool (%s #%d): %s", path, i, err)
        end
        def.source_type = manifest.source_type
        def.source_path = source_path
        def.manifest_path = path
        local ok, append_err = append_unique_tool_defs(defs, seen, { def })
        if not ok then
            return nil, nil, append_err
        end
    end

    sort_tool_defs(defs)
    return defs, source_path, nil
end

local function load_current_tool_map(uci)
    local old_map = {}
    local foreach_ok, foreach_err = uci:foreach(
        common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if s.name and s.server and s.script then
            local def = normalize_tool_def(s)
            local key = make_tool_key(def)
            old_map[key] = {
                def = def,
                enable = s.enable or "0",
                section = s[".name"],
                manifest_path = s.manifest_path or "",
            }
        end
    end)
    if foreach_ok == false and foreach_err then
        return nil, "failed to read tool registry: " .. tostring(foreach_err)
    end
    return old_map, nil
end

sort_tool_defs = function(defs)
    table.sort(defs, function(a, b)
        local ka = make_tool_key(a)
        local kb = make_tool_key(b)
        return ka < kb
    end)
end

local function scan_all_tool_defs()
    local defs = {}
    local seen = {}

    local lua_servers = listup_server_candidate(lua_ubus_server_app_dir)
    if lua_servers then
        for _, server_name in ipairs(lua_servers) do
            local server_defs, err = scan_lua_server_defs(server_name)
            if not server_defs then
                return nil, err
            end
            local ok, append_err = append_unique_tool_defs(defs, seen, server_defs)
            if not ok then
                return nil, append_err
            end
        end
    end

    local ucode_servers = listup_server_candidate(ucode_ubus_server_app_dir)
    if ucode_servers then
        for _, server_name in ipairs(ucode_servers) do
            local server_defs, err = scan_ucode_server_defs(server_name)
            if not server_defs then
                return nil, err
            end
            local ok, append_err = append_unique_tool_defs(defs, seen, server_defs)
            if not ok then
                return nil, append_err
            end
        end
    end

    sort_tool_defs(defs)
    return defs, nil
end

local function add_tool_section(uci, def, enable)
    local s = uci:section(common.db.uci.cfg, common.db.uci.sect.tool)
    if type(s) ~= "string" or s == "" then
        return false, "failed to create tool section"
    end

    local function set_option(option, value)
        local ok, err = uci:set(common.db.uci.cfg, s, option, value)
        if ok ~= true then
            return false, string.format(
                "failed to set tool section %s.%s: %s",
                s, option, tostring(err or "unknown UCI error"))
        end
        return true, nil
    end

    local scalar_options = {
        { "name", def.name },
        { "script", def.script },
        { "server", def.server },
        { "enable", enable or "0" },
        { "type", def.type or "function" },
        { "description", def.description or "" },
        { "execution_message", def.execution_message or "" },
        { "download_message", def.download_message or "" },
        { "timeout", def.timeout or "" },
        { "conflict", def.conflict or "0" },
    }
    for _, option in ipairs(scalar_options) do
        local ok, err = set_option(option[1], option[2])
        if not ok then
            return false, err
        end
    end

    if def.required and #def.required > 0 then
        local ok, err = uci:set_list(
            common.db.uci.cfg, s, "required", def.required)
        if ok ~= true then
            return false, string.format(
                "failed to set tool section %s.required: %s",
                s, tostring(err or "unknown UCI error"))
        end
    end
    if def.property and #def.property > 0 then
        local ok, err = uci:set_list(
            common.db.uci.cfg, s, "property", def.property)
        if ok ~= true then
            return false, string.format(
                "failed to set tool section %s.property: %s",
                s, tostring(err or "unknown UCI error"))
        end
    end

    local ok, err = set_option(
        "additionalProperties", def.additionalProperties or "0")
    if not ok then
        return false, err
    end
    if def.source_type and #tostring(def.source_type) > 0 then
        ok, err = set_option("source_type", def.source_type)
        if not ok then
            return false, err
        end
    end
    if def.source_path and #tostring(def.source_path) > 0 then
        ok, err = set_option("source_path", def.source_path)
        if not ok then
            return false, err
        end
    end
    if def.manifest_path and #tostring(def.manifest_path) > 0 then
        ok, err = set_option("manifest_path", def.manifest_path)
        if not ok then
            return false, err
        end
    end

    return true, s
end

local function count_tool_sections(uci)
    local count = 0
    local foreach_ok, foreach_err = uci:foreach(
        common.db.uci.cfg, common.db.uci.sect.tool, function()
        count = count + 1
    end)
    if foreach_ok == false and foreach_err then
        return nil, "failed to count tool registry: " .. tostring(foreach_err)
    end
    return count, nil
end

local function make_server_tool_key(server_name, tool_name)
    return tostring(server_name or "") .. "\0" .. tostring(tool_name or "")
end

local function list_manifest_tool_sections(uci, manifest_path, legacy_targets)
    local sections = {}
    local foreach_ok, foreach_err = uci:foreach(
        common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        local current_manifest_path = s.manifest_path or ""
        local replaces_legacy = current_manifest_path == ""
            and legacy_targets
            and legacy_targets[make_server_tool_key(s.server, s.name)] == true
        if current_manifest_path == manifest_path or replaces_legacy then
            sections[#sections + 1] = {
                section = s[".name"],
                name = s.name or "",
                server = s.server or "",
                legacy = replaces_legacy == true,
            }
        end
    end)
    if foreach_ok == false and foreach_err then
        return nil, "failed to read manifest-owned tools: "
            .. tostring(foreach_err)
    end
    table.sort(sections, function(a, b)
        return (a.section or "") < (b.section or "")
    end)
    return sections, nil
end

local function render_manifest_apply_commands(plan)
    local commands = {}
    local target = common.db.uci.cfg .. ".@tool[-1]"

    local function add_set(option, value)
        commands[#commands + 1] = string.format("uci set %s.%s=%s", target, option, shell_quote(value))
    end

    local function add_list(option, values)
        for _, value in ipairs(values or {}) do
            commands[#commands + 1] = string.format("uci add_list %s.%s=%s", target, option, shell_quote(value))
        end
    end

    for _, item in ipairs(plan.delete_sections or {}) do
        commands[#commands + 1] = string.format("uci delete %s.%s", common.db.uci.cfg, item.section)
    end

    for _, item in ipairs(plan.add_entries or {}) do
        local def = item.def
        commands[#commands + 1] = string.format("uci add %s %s", common.db.uci.cfg, common.db.uci.sect.tool)
        add_set("name", def.name or "")
        add_set("script", def.script or "")
        add_set("server", def.server or "")
        add_set("enable", item.enable or "0")
        add_set("type", def.type or "function")
        add_set("description", def.description or "")
        add_set("execution_message", def.execution_message or "")
        add_set("download_message", def.download_message or "")
        add_set("timeout", tostring(def.timeout or ""))
        add_set("source_type", def.source_type or "")
        if def.source_path and #tostring(def.source_path) > 0 then
            add_set("source_path", def.source_path)
        end
        add_set("manifest_path", def.manifest_path or plan.manifest_path or "")
        add_list("required", def.required or {})
        add_list("property", def.property or {})
        add_set("additionalProperties", def.additionalProperties or "0")
    end

    if plan.support_value ~= nil and plan.current_support_value ~= plan.support_value then
        commands[#commands + 1] = string.format(
            "uci set %s.%s.local_tool=%s",
            common.db.uci.cfg,
            common.db.uci.sect.support,
            shell_quote(plan.support_value)
        )
    end

    return commands
end

function M.build_manifest_apply_plan(manifest_path, options)
    options = options or {}
    if type(manifest_path) ~= "string" or manifest_path == "" then
        return false, "missing manifest path"
    end

    if not is_regular_file(manifest_path) then
        return false, "manifest not found: " .. manifest_path
    end

    local defs, _, err = load_manifest_file(manifest_path, { strict = true })
    if not defs then
        return false, err or ("failed to load manifest: " .. manifest_path)
    end
    if #defs == 0 then
        return false, "manifest contains no tools: " .. manifest_path
    end

    local plan_uci = uci
    local old_map, old_map_err = load_current_tool_map(plan_uci)
    if not old_map then
        return false, old_map_err or "failed to read current tool registry"
    end
    local legacy_targets = {}
    for _, def in ipairs(defs) do
        legacy_targets[make_server_tool_key(def.server, def.name)] = true
    end
    -- In releases before Manifest ownership was recorded, the same tool may
    -- already exist without manifest_path. Replace only an unowned legacy
    -- section with the exact server+name from this Manifest; sections owned by
    -- another Manifest and unrelated custom tools remain untouched.
    local delete_sections, delete_sections_err = list_manifest_tool_sections(
        plan_uci, manifest_path, legacy_targets)
    if not delete_sections then
        return false, delete_sections_err
            or "failed to read manifest-owned tool registry"
    end
    local current_tool_count, count_err = count_tool_sections(plan_uci)
    if current_tool_count == nil then
        return false, count_err or "failed to count current tool registry"
    end
    local current_support_value, support_err = plan_uci:get(
        common.db.uci.cfg, common.db.uci.sect.support, "local_tool")
    if current_support_value == false then
        return false, "failed to read local tool support: "
            .. tostring(support_err or "unknown UCI error")
    end
    current_support_value = current_support_value or "0"
    local add_entries = {}

    for _, def in ipairs(defs) do
        def.manifest_path = manifest_path

        local normalized = normalize_tool_def(def)
        local key = make_tool_key(normalized)
        local old = old_map[key]
        local enable = "0"
        if old and defs_equal(old.def, normalized) then
            enable = old.enable or "0"
        end

        add_entries[#add_entries + 1] = {
            def = def,
            enable = enable,
        }
    end

    local final_tool_count = current_tool_count - #delete_sections + #add_entries
    local support_value = (final_tool_count > 0) and "1" or "0"
    if options.preserve_local_tool_support == true then
        support_value = current_support_value
    end
    local plan = {
        manifest_path = manifest_path,
        delete_sections = delete_sections,
        add_entries = add_entries,
        current_tool_count = current_tool_count,
        final_tool_count = final_tool_count,
        current_support_value = current_support_value,
        support_value = support_value,
        preserve_local_tool_support = options.preserve_local_tool_support == true,
    }
    plan.commands = render_manifest_apply_commands(plan)

    return true, plan
end

local function command_lists_equal(left, right)
    if type(left) ~= "table" or type(right) ~= "table"
        or #left ~= #right then
        return false
    end
    for i = 1, #left do
        if left[i] ~= right[i] then
            return false
        end
    end
    return true
end

local function stage_manifest_plan(apply_uci, plan)
    for _, item in ipairs(plan.delete_sections or {}) do
        if type(item) ~= "table" or type(item.section) ~= "string"
            or item.section == "" then
            return false, "invalid manifest delete section"
        end
        local delete_ok, delete_err = apply_uci:delete(
            common.db.uci.cfg, item.section)
        if delete_ok ~= true then
            return false, string.format(
                "failed to delete tool section %s: %s",
                item.section,
                tostring(delete_err or "unknown UCI error"))
        end
    end

    for _, item in ipairs(plan.add_entries or {}) do
        if type(item) ~= "table" or type(item.def) ~= "table" then
            return false, "invalid manifest tool entry"
        end
        local add_ok, add_err = add_tool_section(
            apply_uci, item.def, item.enable)
        if not add_ok then
            return false, add_err or "failed to add manifest tool section"
        end
    end

    if plan.support_value ~= "0" and plan.support_value ~= "1" then
        return false, "invalid manifest local tool support value"
    end
    local support_ok, support_err = apply_uci:set(
        common.db.uci.cfg,
        common.db.uci.sect.support,
        "local_tool",
        plan.support_value)
    if support_ok ~= true then
        return false, "failed to set local tool support: "
            .. tostring(support_err or "unknown UCI error")
    end

    local conflict_ok, conflict_err = check_tool_name_conflict(apply_uci)
    if not conflict_ok then
        return false, conflict_err or "failed to update tool conflicts"
    end

    return true, nil
end

function M.apply_manifest_plan(plan)
    if type(plan) ~= "table" or type(plan.manifest_path) ~= "string"
        or plan.manifest_path == "" or type(plan.commands) ~= "table" then
        return false, "invalid manifest apply plan"
    end

    local operation_ok, info_or_err = uci_transaction.run({
        cursor = uci,
        config = common.db.uci.cfg,
        label = "Oasis manifest apply",
    }, function(apply_uci)
        -- The preview may have been displayed before confirmation. Rebuild it
        -- after acquiring the lock and inside the isolated session, then stop
        -- if any targeted command changed instead of applying a stale plan.
        local current_ok, current_plan = M.build_manifest_apply_plan(
            plan.manifest_path, {
                preserve_local_tool_support = plan.preserve_local_tool_support == true,
            })
        if not current_ok then
            return false, current_plan
                or "failed to rebuild manifest apply plan"
        end
        if not command_lists_equal(plan.commands, current_plan.commands) then
            return false,
                "manifest apply plan changed; review and confirm it again"
        end

        local staged, stage_err = stage_manifest_plan(
            apply_uci, current_plan)
        if not staged then
            return false, stage_err
        end

        return true, {
            added = #(current_plan.add_entries or {}),
            removed = #(current_plan.delete_sections or {}),
            manifest_path = current_plan.manifest_path,
        }
    end)

    if not operation_ok then
        return false, info_or_err or "manifest apply failed"
    end
    if type(info_or_err) == "table" and info_or_err.warning then
        debug:log(
            "oasis.log",
            "apply_manifest_plan",
            "manifest committed with cleanup warning: "
                .. tostring(info_or_err.warning))
    end
    return true, info_or_err
end

function M.apply_manifest_file(manifest_path, options)
    local ok, plan_or_err = M.build_manifest_apply_plan(manifest_path, options)
    if not ok then
        return false, plan_or_err
    end

    return M.apply_manifest_plan(plan_or_err)
end

function M.enable_remote_mcp_support()
    return uci_transaction.run({
        cursor = uci,
        config = common.db.uci.cfg,
        label = "Oasis remote MCP support",
    }, function(apply_uci)
        local current, get_err = apply_uci:get(
            common.db.uci.cfg,
            common.db.uci.sect.support,
            "remote_mcp_server")
        if current == false then
            return false, "failed to read remote MCP support: "
                .. tostring(get_err or "unknown UCI error")
        end
        if current == "1" then
            return true, { changed = false }
        end

        local set_ok, set_err = apply_uci:set(
            common.db.uci.cfg,
            common.db.uci.sect.support,
            "remote_mcp_server",
            "1")
        if set_ok ~= true then
            return false, "failed to enable remote MCP support: "
                .. tostring(set_err or "unknown UCI error")
        end

        return true, { changed = true }
    end)
end

local function apply_tool_defs(defs)
    return uci_transaction.run({
        cursor = uci,
        config = common.db.uci.cfg,
        label = "Oasis tool registry refresh",
    }, function(apply_uci)
        -- Read the enable snapshot only after the global transaction lock is
        -- held. This prevents refresh from overwriting a concurrent manager
        -- or LuCI state change with a stale value.
        local old_map, old_map_err = load_current_tool_map(apply_uci)
        if not old_map then
            return false, old_map_err or "failed to read tool registry"
        end

        local current_count, count_err = count_tool_sections(apply_uci)
        if current_count == nil then
            return false, count_err or "failed to count tool registry"
        end
        if current_count > 0 then
            local delete_ok, delete_err = apply_uci:delete_all(
                common.db.uci.cfg, common.db.uci.sect.tool)
            if delete_ok ~= true then
                return false, "failed to clear tool registry: "
                    .. tostring(delete_err or "unknown UCI error")
            end
        end

        for _, def in ipairs(defs or {}) do
            local normalized = normalize_tool_def(def)
            local key = make_tool_key(normalized)
            local old = old_map[key]
            local enable = "0"
            if old and defs_equal(old.def, normalized) then
                enable = old.enable or "0"
            end
            local add_ok, add_err = add_tool_section(
                apply_uci, def, enable)
            if not add_ok then
                return false, add_err
                    or "failed to add tool registry entry"
            end
        end

        local support_ok, support_err = apply_uci:set(
            common.db.uci.cfg,
            common.db.uci.sect.support,
            "local_tool",
            (#(defs or {}) > 0) and "1" or "0")
        if support_ok ~= true then
            return false, "failed to update local tool support: "
                .. tostring(support_err or "unknown UCI error")
        end
        local conflict_ok, conflict_err = check_tool_name_conflict(
            apply_uci)
        if not conflict_ok then
            return false, conflict_err
                or "failed to update tool conflicts"
        end

        return true, { count = #(defs or {}) }
    end)
end

function M.setup_lua_server_config(server_name)
    local defs, err = scan_lua_server_defs(server_name)
    if not defs then
        debug:log("oasis.log", "setup_lua_server_config", err or "failed to scan lua server")
        return false, err
    end
    for _, def in ipairs(defs) do
        local add_ok, add_err = add_tool_section(uci, def, "0")
        if not add_ok then
            return false, add_err or "failed to add lua tool section"
        end
    end
    if #defs > 0 then
        local support_ok, support_err = uci:set(
            common.db.uci.cfg,
            common.db.uci.sect.support,
            "local_tool",
            "1")
        if support_ok ~= true then
            return false, "failed to update local tool support: "
                .. tostring(support_err or "unknown UCI error")
        end
        local commit_ok, commit_err = uci:commit(common.db.uci.cfg)
        if commit_ok ~= true then
            return false, "failed to commit lua tool registry: "
                .. tostring(commit_err or "unknown UCI error")
        end
    end
    return true, { count = #defs }
end

function M.setup_ucode_server_config(server_name)
    local defs, err = scan_ucode_server_defs(server_name)
    if not defs then
        debug:log("oasis.log", "setup_ucode_server_config", err or "failed to scan ucode server")
        return false, err
    end
    for _, def in ipairs(defs) do
        local add_ok, add_err = add_tool_section(uci, def, "0")
        if not add_ok then
            return false, add_err or "failed to add ucode tool section"
        end
    end
    if #defs > 0 then
        local support_ok, support_err = uci:set(
            common.db.uci.cfg,
            common.db.uci.sect.support,
            "local_tool",
            "1")
        if support_ok ~= true then
            return false, "failed to update local tool support: "
                .. tostring(support_err or "unknown UCI error")
        end
        local commit_ok, commit_err = uci:commit(common.db.uci.cfg)
        if commit_ok ~= true then
            return false, "failed to commit ucode tool registry: "
                .. tostring(commit_err or "unknown UCI error")
        end
    end
    return true, { count = #defs }
end

listup_server_candidate = function(dir)
  local files = fs.dir(dir)
  if not files then
    return nil
  end

  local result = {}
  for file in files do
    local path = dir .. file
    -- Ignore directories and special files; only regular files are candidates.
    if is_regular_file(path) then
        table.insert(result, file)
    end
  end
  table.sort(result)
  return result
end

local function listup_manifest_candidate(dir)
    local files = fs.dir(dir)
    if not files then
        return {}
    end

    local result = {}
    for file in files do
        local path = dir .. file
        if is_regular_file(path) and file:sub(-5) == ".json" then
            table.insert(result, file)
        end
    end

    table.sort(result)
    return result
end

local function load_all_manifest_defs()
    local defs = {}
    local seen = {}

    for _, file in ipairs(listup_manifest_candidate(manifest_dir)) do
        local manifest_defs, _, err = load_manifest_file(manifest_dir .. file)
        if not manifest_defs then
            return nil, err
        end
        local ok, append_err = append_unique_tool_defs(defs, seen, manifest_defs)
        if not ok then
            return nil, append_err
        end
    end

    sort_tool_defs(defs)
    return defs, nil
end

local function collect_all_manifests()
    local manifests = {}

    local lua_servers = listup_server_candidate(lua_ubus_server_app_dir)
    if lua_servers then
        for _, server_name in ipairs(lua_servers) do
            local defs, err = scan_lua_server_defs(server_name)
            if not defs then
                return nil, err
            end
            if #defs > 0 then
                manifests[#manifests + 1] = build_manifest("lua", lua_ubus_server_app_dir .. server_name, defs)
            end
        end
    end

    local ucode_servers = listup_server_candidate(ucode_ubus_server_app_dir)
    if ucode_servers then
        for _, server_name in ipairs(ucode_servers) do
            local defs, err = scan_ucode_server_defs(server_name)
            if not defs then
                return nil, err
            end
            if #defs > 0 then
                manifests[#manifests + 1] = build_manifest("ucode", ucode_ubus_server_app_dir .. server_name, defs)
            end
        end
    end

    table.sort(manifests, function(a, b)
        return manifest_filename(a.source_type, a.source_path) < manifest_filename(b.source_type, b.source_path)
    end)

    return manifests, nil
end

function M.rebuild_manifest_store()
    local manifests, err = collect_all_manifests()
    if not manifests then
        debug:log("oasis.log", "rebuild_manifest_store", err or "failed to collect manifests")
        return false, err or "failed to collect manifests"
    end

    if not fs.stat(manifest_dir) and not fs.mkdirr(manifest_dir) then
        return false, "failed to create manifest dir"
    end

    for _, file in ipairs(listup_manifest_candidate(manifest_dir)) do
        if not fs.remove(manifest_dir .. file) then
            return false, "failed to remove old manifest: " .. file
        end
    end

    for _, manifest in ipairs(manifests) do
        local ok, path_or_err = write_manifest_file(manifest)
        if not ok then
            debug:log("oasis.log", "rebuild_manifest_store", path_or_err or "failed to write manifest")
            return false, path_or_err or "failed to write manifest"
        end
    end

    return true, { count = #manifests }
end

function M.build_manifest_for_script(script_path)
    if type(script_path) ~= "string" or script_path == "" then
        return false, "missing script path"
    end

    local manifest_script_path = resolve_manifest_script_path(script_path)
    local script_type = detect_script_type(manifest_script_path)
    local defs, err

    if script_type == "ucode" then
        defs, err = scan_ucode_script_defs(script_path)
    else
        defs, err = scan_lua_script_defs(script_path, basename(manifest_script_path))
    end

    if not defs then
        debug:log("oasis.log", "build_manifest_for_script", err or ("failed to scan tool script: " .. script_path))
        return false, err or ("failed to scan tool script: " .. script_path)
    end

    if #defs == 0 then
        return false, "no tools found in script: " .. script_path
    end

    return true, build_manifest(script_type, manifest_script_path, defs)
end

function M.list_manifest_candidate_scripts()
    local result = {}

    local lua_servers = listup_server_candidate(lua_ubus_server_app_dir)
    if lua_servers then
        for _, server_name in ipairs(lua_servers) do
            local script_path = lua_ubus_server_app_dir .. server_name
            if is_oasis_tool_server(script_path) then
                result[#result + 1] = script_path
            end
        end
    end

    local ucode_servers = listup_server_candidate(ucode_ubus_server_app_dir)
    if ucode_servers then
        for _, server_name in ipairs(ucode_servers) do
            local script_path = ucode_ubus_server_app_dir .. server_name
            if is_oasis_tool_server(script_path) then
                result[#result + 1] = script_path
            end
        end
    end

    table.sort(result)
    return result
end

function M.list_manifest_targets()
    local result = {}

    for _, script_path in ipairs(M.list_manifest_candidate_scripts()) do
        local script_type = detect_script_type(script_path)
        result[#result + 1] = {
            script_path = script_path,
            manifest_path = manifest_dir .. manifest_filename(script_type, script_path),
        }
    end

    return result
end

function M.list_manifest_files()
    local result = {}

    for _, file in ipairs(listup_manifest_candidate(manifest_dir)) do
        result[#result + 1] = manifest_dir .. file
    end

    return result
end

check_tool_name_conflict = function(uci)
    -- Check Conflict Tool Name
    -- If the value of the conflict option is set to 1, usage will be prohibited.
    local name_to_sections = {}
    local mutation_err
    local foreach_ok, foreach_err = uci:foreach(
        common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        local section_name = s[".name"]
        if type(section_name) ~= "string" or section_name == "" then
            mutation_err = "tool registry contains an invalid section"
            return false
        end
        local reset_ok, reset_err = uci:set(
            common.db.uci.cfg, section_name, "conflict", "0")
        if reset_ok ~= true then
            mutation_err = string.format(
                "failed to reset tool conflict for %s: %s",
                section_name,
                tostring(reset_err or "unknown UCI error"))
            return false
        end
        if s.name then
            name_to_sections[s.name] = name_to_sections[s.name] or {}
            table.insert(name_to_sections[s.name], section_name)
        end
    end)
    if mutation_err then
        return false, mutation_err
    end
    if foreach_ok == false and foreach_err then
        return false, "failed to read tool conflicts: "
            .. tostring(foreach_err)
    end

    for _, sections in pairs(name_to_sections) do
        if #sections > 1 then
            for _, sec in ipairs(sections) do
                local conflict_ok, conflict_err = uci:set(
                    common.db.uci.cfg, sec, "conflict", "1")
                if conflict_ok ~= true then
                    return false, string.format(
                        "failed to set tool conflict for %s: %s",
                        sec,
                        tostring(conflict_err or "unknown UCI error"))
                end
            end
        end
    end
    return true, nil
end

function M.update_server_info()
    local defs = {}
    local seen = {}

    local manifest_defs, err = load_all_manifest_defs()
    if not manifest_defs then
        debug:log("oasis.log", "update_server_info", err or "failed to load manifest definitions")
        return false, err or "failed to load manifest definitions"
    end
    local ok, append_err = append_unique_tool_defs(defs, seen, manifest_defs)
    if not ok then
        debug:log("oasis.log", "update_server_info", append_err or "failed to merge manifest definitions")
        return false, append_err or "failed to merge manifest definitions"
    end

    sort_tool_defs(defs)

    local apply_ok, info_or_err = apply_tool_defs(defs)
    if not apply_ok then
        debug:log("oasis.log", "update_server_info", info_or_err or "failed to apply tool definitions")
        return false, info_or_err or "failed to apply tool definitions"
    end

    return true, info_or_err
end

-- This function is called when sending a message to the LLM.
function M.get_function_call_schema()
    local tools = {}
    local name_counts = {}
    local effective, state_err = tool_state.snapshot(uci)
    if not effective then error(state_err.error) end
    local tool_snapshot = effective.tools
    for _, snapshot in ipairs(tool_snapshot) do
        if snapshot.name then
            name_counts[snapshot.name] =
                (name_counts[snapshot.name] or 0) + 1
        end
    end

    for _, s in ipairs(tool_snapshot) do
        -- A conflicted function name cannot be addressed unambiguously by
        -- provider Function Calling, which carries the function name but not
        -- the backing ubus server. Reserved manager names must additionally
        -- resolve to oasis.tool.manager so another server cannot impersonate
        -- a persistent management operation.
        local reserved_control_name =
            tool_state.is_control_tool(control_tool_server, s.name)
        local valid_control_binding = not reserved_control_name
            or tool_state.is_control_tool(s.server, s.name)
        if s.enable == "1" and s.conflict ~= "1"
            and name_counts[s.name] == 1 and valid_control_binding then
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
                name = s["name"],
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
    end
    return tools
end

local function handle_option_message(msg, msg_type, format)
    if not msg then return end

    local option = {
        type = msg_type,
        message = msg
    }
    local option_json = jsonc.stringify(option, false)

    if (format == common.ai.format.output) and option_json and (#option_json > 0) then
        debug:log("oasis.log", "handle_option_message", option_json)
        io.write(option_json)
        io.flush()
    elseif ((format == common.ai.format.chat) or (format == common.ai.format.prompt)) and option.message then
        io.write(option.message .. "\n\n")
        io.flush()
    end
end

function M.exec_server_tool(format, tool, data, expected_mode_token)

    local nixio = require("nixio")
    local found = false
    local result = {}
    local effective, state_err = tool_state.snapshot(uci, expected_mode_token)
    if not effective then return state_err end
    local tool_snapshot = effective.tools

    local function is_sensitive_debug_key(key)
        local normalized = tostring(key or ""):lower()
        return normalized == "config"
            or normalized == "key"
            or normalized:match("^key%d*$") ~= nil
            or normalized:find("password", 1, true) ~= nil
            or normalized:find("secret", 1, true) ~= nil
            or normalized:find("private_key", 1, true) ~= nil
    end

    local function redact_debug_value(value, key)
        if is_sensitive_debug_key(key) then
            return "[redacted]"
        end
        if type(value) ~= "table" then
            return value
        end

        local redacted = {}
        for child_key, child_value in pairs(value) do
            redacted[child_key] = redact_debug_value(child_value, child_key)
        end
        return redacted
    end

    local function merge_parsed_result(tbl)
        if type(tbl) ~= "table" then
            return tbl
        end

        local raw = tbl.result
        if type(raw) == "string" then
            local parsed = jsonc.parse(raw)
            if type(parsed) == "table" then
                for k, v in pairs(parsed) do
                    if tbl[k] == nil then
                        tbl[k] = v
                    end
                end
            end
        end
        return tbl
    end

    local matches = {}
    for _, snapshot in ipairs(tool_snapshot) do
        debug:log("oasis.log", "exec_server_tool",
            "config: s.server = " .. tostring(snapshot.server or ""))
        debug:log("oasis.log", "exec_server_tool",
            "config: s.name   = " .. tostring(snapshot.name or ""))
        debug:log("oasis.log", "exec_server_tool",
            "config: s.enable = " .. tostring(snapshot.enable or ""))
        if snapshot.name == tool then
            matches[#matches + 1] = snapshot
        end
    end

    -- Function Calling identifies a tool by name only. Resolve exactly one
    -- immutable snapshot, then execute at most that one target.
    local s = (#matches == 1) and matches[1] or nil
    local reserved_control_name =
        tool_state.is_control_tool(control_tool_server, tool)
    local valid_control_binding = not reserved_control_name
        or (s and tool_state.is_control_tool(s.server, s.name))
    if s and valid_control_binding
        and s.enable == "1" and s.conflict ~= "1" then
            handle_option_message(s.execution_message, "execution", format)
            handle_option_message(s.download_message,  "download",  format)

            found = true
            -- Tool arguments can contain passwords or serialized configuration.
            -- Never write those values to the shared Oasis debug log.
            debug:log("oasis.log", "exec_server_tool",
                "request payload = " .. jsonc.stringify(redact_debug_value(data), false))
            result = ubus_call(s.server, s.name, data, s.timeout)
            result = merge_parsed_result(result)
            debug:log("oasis.log", "exec_server_tool", string.format("Result for tool '%s' (response) = %s", s.name, tostring(jsonc.stringify(result, false))))

            -- [Control install package]
            -- The following code monitors the installation of packages triggered by the AI tool
            -- (UBUS server application). Once the installation process is complete, it verifies
            -- whether the package was successfully installed. If a failure is detected,
            -- it overrides the AI tool’s standard response and notifies the AI with the message
            -- : "Failed to install <pkg> package."
            --
            -- Note (Tips):
            -- The UBUS server application cannot monitor the package installation process.
            -- This is because the UBUS server application experiences a deadlock immediately
            -- after the package manager software begins unpacking the package. Therefore,
            -- the UBUS process is terminated before the deadlock occurs, and the monitoring and installation
            -- completion verification are performed at this point.
            if misc.check_file_exist(common.file.pkg.install) then
                local install_pkg_info = misc.read_file(common.file.pkg.install)
                os.remove(common.file.pkg.install)
                debug:log("oasis.log", "exec_server_tool", "pid = " .. install_pkg_info)

                local pkg, pid = install_pkg_info:match("([^|]+)|([^|]+)")

                local timeout = tonumber(uci:get("rpcd", "@rpcd[0]", "timeout")) or 30
                local elapsed = 0

                local is_install_success = false

                while elapsed < timeout do
                    debug:log("oasis.log", "install_pkg", "elapsed = " .. elapsed)
                    if not mgr.check_process_alive(pid) then
                        debug:log("oasis.log", "install_pkg", "child exited")

                        if mgr.check_installed_pkg(pkg) then
                            debug:log("oasis.log", "install_pkg", "Check Installed Package OK (" .. pkg .. ")")
                            is_install_success = true
                            break
                        else
                            debug:log("oasis.log", "install_pkg", "Check Installed Package FAILED (" .. pkg .. ")")
                            is_install_success = false
                            break
                        end
                    end

                    nixio.nanosleep(1, 0)
                    elapsed = elapsed + 1
                end

                if not is_install_success then
                    debug:log("oasis.log", "exec_server_tool", "Failed to install package.")
                    -- Overwrite UBUS Result
                    result = { error = "Failed to install " .. pkg .. " package." }
                end

                -- After a package is successfully installed, the system checks whether a reboot is required.
                -- If a reboot is necessary, a file named after the corresponding package is placed in
                -- /tmp/oasis/pkg_reboot_required. Normally, when reboot = true, the WebUI displays a popup
                -- prompting the user to reboot the system.

                -- However, this flag is designed with the assumption that the user may ignore the prompt and later ask
                -- the AI to execute tools that function correctly only after a reboot.
                -- Tools that need to run post-reboot can use the check_pkg_reboot_required function to verify whether
                -- the system has been rebooted. If no <pkg> file exists in /tmp/oasis/pkg_reboot_required, it is considered
                -- that the reboot has been completed.
                if result.reboot then
                    misc.touch(common.file.pkg.reboot_required_path  .. pkg)
                end

                -- restart_service handling moved outside this block to run regardless of package install
            end
        end

        -- Always handle restart_service regardless of package install monitoring
        if result.prepare_service_restart then
            -- The variable restart_service stores the name of the service to be restarted (e.g., "network").
            -- It checks whether the service exists directly under /etc/init.d; if it does not exist, restart_service is deleted.
            -- If the service exists, a restart request flag is created under /tmp/oasis.
            local svc = tostring(result.prepare_service_restart or "")
            debug:log("oasis.log", "exec_server_tool", "svc = " .. svc)
            if not misc.check_init_script_exists(svc) then
                debug:log("oasis.log", "exec_server_tool", svc .. " not found under /etc/init.d; skip creating restart flag")
                result.prepare_service_restart = nil
            else
                debug:log("oasis.log", "exec_server_tool", "create file: " .. common.file.service.restart_required)
                misc.write_file(common.file.service.restart_required, svc)
            end
        end

    if not found then
        -- Handles cases where the AI requests a non-existent tool.
        -- This typically indicates hallucination. The system notifies the AI accordingly.
        -- This does not fix LLM-level issues, but helps prevent JSON or communication errors between AI and system.
        result = {
            error = "tool_not_recognized",
            message ="The requested tool is not recognized on this system.",
            cause = "hallucination"
        }

        debug:log("oasis.log", "exec_server_tool", string.format("Tool '%s' not found or not enabled.", tool))
    end

    return result
end

return M
