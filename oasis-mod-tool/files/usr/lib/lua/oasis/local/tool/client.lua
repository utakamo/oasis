local uci       = require("luci.model.uci").cursor()
local common    = require("oasis.common")
local misc      = require("oasis.chat.misc")
local mgr       = require("oasis.local.tool.package.manager")
local debug     = require("oasis.chat.debug")
local jsonc     = require("luci.jsonc")
local sys       = require("luci.sys")
local fs        = require("nixio.fs")

local M = {}

local lua_ubus_server_app_dir = "/usr/libexec/rpcd/"
local ucode_ubus_server_app_dir = "/usr/share/rpcd/ucode/"
local listup_server_candidate
local check_tool_name_conflict

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

local ubus_call = function(path, method, param, timeout)

    local ubus = require("ubus")
    local conn

    if timeout and type(timeout) == "string" and #timeout > 0 then
        conn = ubus.connect(nil, tonumber(timeout))
    elseif timeout and type(timeout) == "number" and timeout > 0 then
        conn = ubus.connect(nil, timeout)
    else
        -- default: 60s
        conn = ubus.connect(nil, 60000)
    end

    if not conn then
        return { error = "Failed to connect to ubus" }
    end

    local result, err = conn:call(path, method, param)
    conn:close()

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

    if not is_oasis_tool_server(server_path) then
        debug:log("oasis.log", "scan_lua_server_defs", "skip non-oasis server file: " .. server_name)
        return {}, nil
    end

    local meta = sys.exec(shell_quote(server_path) .. " meta 2>/dev/null")
    local data = jsonc.parse(meta)
    if not data then
        return nil, "invalid lua tool metadata: " .. server_name
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

    if not misc.check_file_exist("/usr/bin/ucode") then
        return nil, "ucode not installed"
    end

    local meta = sys.exec("ucode " .. shell_quote(server_path) .. " 2>/dev/null")
    local data = jsonc.parse(meta)
    if not data then
        return nil, "invalid ucode tool metadata: " .. server_name
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

local function load_current_tool_map(uci_cursor)
    local old_map = {}
    uci_cursor:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if s.name and s.server and s.script then
            local def = normalize_tool_def(s)
            local key = make_tool_key(def)
            old_map[key] = { def = def, enable = s.enable or "0" }
        end
    end)
    return old_map
end

local function sort_tool_defs(defs)
    table.sort(defs, function(a, b)
        local ka = make_tool_key(a)
        local kb = make_tool_key(b)
        return ka < kb
    end)
end

local function scan_all_tool_defs()
    local defs = {}
    local seen = {}

    local function append_defs(server_defs)
        for _, def in ipairs(server_defs or {}) do
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

    local lua_servers = listup_server_candidate(lua_ubus_server_app_dir)
    if lua_servers then
        for _, server_name in ipairs(lua_servers) do
            local server_defs, err = scan_lua_server_defs(server_name)
            if not server_defs then
                return nil, err
            end
            local ok, append_err = append_defs(server_defs)
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
            local ok, append_err = append_defs(server_defs)
            if not ok then
                return nil, append_err
            end
        end
    end

    sort_tool_defs(defs)
    return defs, nil
end

local function add_tool_section(uci_cursor, def, enable)
    local s = uci_cursor:section(common.db.uci.cfg, common.db.uci.sect.tool)
    uci_cursor:set(common.db.uci.cfg, s, "name", def.name)
    uci_cursor:set(common.db.uci.cfg, s, "script", def.script)
    uci_cursor:set(common.db.uci.cfg, s, "server", def.server)
    uci_cursor:set(common.db.uci.cfg, s, "enable", enable or "0")
    uci_cursor:set(common.db.uci.cfg, s, "type", def.type or "function")
    uci_cursor:set(common.db.uci.cfg, s, "description", def.description or "")
    uci_cursor:set(common.db.uci.cfg, s, "execution_message", def.execution_message or "")
    uci_cursor:set(common.db.uci.cfg, s, "download_message", def.download_message or "")
    uci_cursor:set(common.db.uci.cfg, s, "timeout", def.timeout or "")
    uci_cursor:set(common.db.uci.cfg, s, "conflict", def.conflict or "0")
    if def.required and #def.required > 0 then
        uci_cursor:set_list(common.db.uci.cfg, s, "required", def.required)
    end
    if def.property and #def.property > 0 then
        uci_cursor:set_list(common.db.uci.cfg, s, "property", def.property)
    end
    uci_cursor:set(common.db.uci.cfg, s, "additionalProperties", def.additionalProperties or "0")
end

local function apply_tool_defs(defs)
    local apply_uci = require("luci.model.uci").cursor()
    local old_map = load_current_tool_map(apply_uci)

    apply_uci:delete_all(common.db.uci.cfg, common.db.uci.sect.tool)

    for _, def in ipairs(defs or {}) do
        local normalized = normalize_tool_def(def)
        local key = make_tool_key(normalized)
        local old = old_map[key]
        local enable = "0"
        if old and defs_equal(old.def, normalized) then
            enable = old.enable or "0"
        end
        add_tool_section(apply_uci, def, enable)
    end

    apply_uci:set(common.db.uci.cfg, common.db.uci.sect.support, "local_tool", (#(defs or {}) > 0) and "1" or "0")
    check_tool_name_conflict(apply_uci)

    local ok = apply_uci:commit(common.db.uci.cfg)
    if ok == false then
        return false, "failed to commit tool registry"
    end
    return true, { count = #(defs or {}) }
end

function M.setup_lua_server_config(server_name)
    local defs, err = scan_lua_server_defs(server_name)
    if not defs then
        debug:log("oasis.log", "setup_lua_server_config", err or "failed to scan lua server")
        return false, err
    end
    for _, def in ipairs(defs) do
        add_tool_section(uci, def, "0")
    end
    if #defs > 0 then
        uci:set(common.db.uci.cfg, common.db.uci.sect.support, "local_tool", "1")
        uci:commit(common.db.uci.cfg)
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
        add_tool_section(uci, def, "0")
    end
    if #defs > 0 then
        uci:set(common.db.uci.cfg, common.db.uci.sect.support, "local_tool", "1")
        uci:commit(common.db.uci.cfg)
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

check_tool_name_conflict = function(uci_cursor)
    uci_cursor = uci_cursor or uci
    -- Check Conflict Tool Name
    -- If the value of the conflict option is set to 1, usage will be prohibited.
    local name_to_sections = {}
    uci_cursor:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if s.name then
            name_to_sections[s.name] = name_to_sections[s.name] or {}
            table.insert(name_to_sections[s.name], s[".name"])
        end
    end)
    for _, sections in pairs(name_to_sections) do
        if #sections > 1 then
            for _, sec in ipairs(sections) do
                uci_cursor:set(common.db.uci.cfg, sec, "conflict", "1")
            end
        end
    end
end

function M.update_server_info()
    local defs, err = scan_all_tool_defs()
    if not defs then
        debug:log("oasis.log", "update_server_info", err or "failed to scan tool definitions")
        return false, err or "failed to scan tool definitions"
    end

    local ok, info_or_err = apply_tool_defs(defs)
    if not ok then
        debug:log("oasis.log", "update_server_info", info_or_err or "failed to apply tool definitions")
        return false, info_or_err or "failed to apply tool definitions"
    end

    return true, info_or_err
end

-- This function is called when sending a message to the LLM.
function M.get_function_call_schema()
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
    end)
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

function M.exec_server_tool(format, tool, data)

    local nixio = require("nixio")
    local found = false
    local result = {}

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

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)

        debug:log("oasis.log", "exec_server_tool", "config: s.server = " .. s.server)
        debug:log("oasis.log", "exec_server_tool", "config: s.name   = " .. s.name)
        debug:log("oasis.log", "exec_server_tool", "config: s.enable = " .. s.enable)

        if s.name == tool and s.enable == "1" then
            handle_option_message(s.execution_message, "execution", format)
            handle_option_message(s.download_message,  "download",  format)

            found = true
            debug:log("oasis.log", "exec_server_tool", "request payload = " .. jsonc.stringify(data, false))
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
    end)

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
