local uci       = require("luci.model.uci").cursor()
local common    = require("oasis.common")
local misc      = require("oasis.chat.misc")
local mgr       = require("oasis.local.tool.package.manager")
local debug     = require("oasis.chat.debug")
local jsonc     = require("luci.jsonc")
local sys       = require("luci.sys")
local fs        = require("nixio.fs")

local lua_ubus_server_app_dir = "/usr/libexec/rpcd/"
local ucode_ubus_server_app_dir = "/usr/share/rpcd/ucode/"

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

local setup_lua_server_config = function(server_name)
    local server_path = lua_ubus_server_app_dir .. server_name
    local meta = sys.exec(server_path .. " meta")

    -- Todo:
    -- Check meta command success

    local data = jsonc.parse(meta)

    if not data then
        debug:log("oasis.log", "setup_lua_server_config", server_name .. " is not olt server...")
        return
    end
    debug:log("oasis.log", "setup_lua_server_config", server_name .. " is olt server!!")
    uci:set(common.db.uci.cfg, common.db.uci.sect.support, "local_tool", "1")

    local created_sections = {}

    for tool_name, tool in pairs(data) do
        local s = uci:section(common.db.uci.cfg, common.db.uci.sect.tool)
        uci:set(common.db.uci.cfg, s, "name", tool_name)
        uci:set(common.db.uci.cfg, s, "script", "lua")
        uci:set(common.db.uci.cfg, s, "server", server_name)
        uci:set(common.db.uci.cfg, s, "enable", "0")
        uci:set(common.db.uci.cfg, s, "type", "function")
        uci:set(common.db.uci.cfg, s, "description", tool.tool_desc or "")
        uci:set(common.db.uci.cfg, s, "execution_message", tool.exec_msg or "")
        uci:set(common.db.uci.cfg, s, "download_message", tool.download_msg or "")
        uci:set(common.db.uci.cfg, s, "timeout", tool.timeout or "")
        uci:set(common.db.uci.cfg, s, "conflict", "0")

        -- required / properties: set_list with arrays for all params
        local params = {}
        if tool.args and type(tool.args) == "table" then
            for param, _ in pairs(tool.args) do
                params[#params + 1] = param
            end
            table.sort(params)

            local required_list = {}
            local property_list = {}

            local type_map = { a_string = "string", integer = "number", boolean = "boolean", number = "number", string = "string" }
            for i, param in ipairs(params) do
                required_list[#required_list + 1] = param
                local typ  = tool.args[param]
                local desc = ""
                if tool.args_desc and type(tool.args_desc) == "table" then
                    desc = tool.args_desc[i] or ""
                end
                local uci_type = type_map[typ] or "string"
                property_list[#property_list + 1] = string.format("%s:%s:%s", param, uci_type, desc)
            end

            uci:set_list(common.db.uci.cfg, s, "required", required_list)
            uci:set_list(common.db.uci.cfg, s, "property", property_list)
        end
        uci:set(common.db.uci.cfg, s, "additionalProperties", "0")
        table.insert(created_sections, {section = s, name = tool_name})
    end
    uci:commit(common.db.uci.cfg)
end

local setup_ucode_server_config = function(server_name)

    -- Check ucode binary
    if not misc.check_file_exist("/usr/bin/ucode") then
        debug:log("oasis.log", "setup_ucode_server_config", "ucode not installed; skip")
        return
    end

    local server_path = ucode_ubus_server_app_dir .. server_name
    -- Check target ucode script
    if not misc.check_file_exist(server_path) then
        debug:log("oasis.log", "setup_ucode_server_config", "script not found: " .. server_path)
        return
    end
    local meta = sys.exec("ucode " .. server_path)
    debug:log("oasis.log", "setup_ucode_server_config", meta)

    local data = jsonc.parse(meta)

    if not data then
        debug:log("oasis.log", "setup_ucode_server_config", "Script: " .. server_name .. " is not olt server...")
        return
    end
    debug:log("oasis.log", "setup_ucode_server_config", server_name .. " is olt server!!")
    uci:set(common.db.uci.cfg, common.db.uci.sect.support, "local_tool", "1")

    local created_sections = {}

    local function detect_type(v)
        local t = type(v)
        if t == "number" then return "number"
        elseif t == "boolean" then return "boolean"
        elseif t == "string" then return "string"
        else return "string" end
    end

    for server, tbl in pairs(data) do
        for tool, def in pairs(tbl) do
            local s = uci:section(common.db.uci.cfg, common.db.uci.sect.tool)
            uci:set(common.db.uci.cfg, s, "name", tool)
            uci:set(common.db.uci.cfg, s, "script", "ucode")
            uci:set(common.db.uci.cfg, s, "server", server)
            uci:set(common.db.uci.cfg, s, "enable", "0")
            uci:set(common.db.uci.cfg, s, "type", "function")
            uci:set(common.db.uci.cfg, s, "description", def.tool_desc or "")
            uci:set(common.db.uci.cfg, s, "execution_message", def.exec_msg or "")
            uci:set(common.db.uci.cfg, s, "download_message", def.download_msg or "")
            uci:set(common.db.uci.cfg, s, "timeout", def.timeout or "")
            uci:set(common.db.uci.cfg, s, "conflict", "0")

            -- required / properties: set_list with arrays for all params
            local params = {}
            if def.args and type(def.args) == "table" then
                for param, _ in pairs(def.args) do
                    params[#params + 1] = param
                end
                table.sort(params)

                local required_list = {}
                local property_list = {}

                for i, param in ipairs(params) do
                    required_list[#required_list + 1] = param
                    local typ  = detect_type(def.args[param])
                    local desc = ""
                    if def.args_desc and type(def.args_desc) == "table" then
                        desc = def.args_desc[i] or ""
                    end
                    property_list[#property_list + 1] = string.format("%s:%s:%s", param, typ, desc)
                end

                uci:set_list(common.db.uci.cfg, s, "required", required_list)
                uci:set_list(common.db.uci.cfg, s, "property", property_list)
            end
            uci:set(common.db.uci.cfg, s, "additionalProperties", "0")
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

    -- 1) Create a snapshot of the old UCI (only 'enable' will be restored; comparisons require an exact match)
    local function to_list(v)
        if v == nil then return {} end
        if type(v) == "table" then return v end
        return { v }
    end

    local function normalize_from_uci_section(s)
        local required = to_list(s.required)
        local props    = to_list(s.property)
        table.sort(required)
        table.sort(props)
        return {
            name = s.name or "",
            script = s.script or "",
            server = s.server or "",
            type = s.type or "function",
            description = s.description or "",
            additionalProperties = s.additionalProperties or "0",
            required = required,
            properties = props,
        }
    end

    local function make_key(def)
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
        if #a.properties ~= #b.properties then return false end
        for i = 1, #a.properties do
            if a.properties[i] ~= b.properties[i] then return false end
        end
        return true
    end

    local old_map = {}
    uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if s.name and s.server and s.script then
            local def = normalize_from_uci_section(s)
            local key = make_key(def)
            old_map[key] = { def = def, enable = s.enable or "0" }
        end
    end)

    do
        local cnt = 0
        for _ in pairs(old_map) do cnt = cnt + 1 end
        debug:log("oasis.log", "update_server_info", "snapshot_count=" .. tostring(cnt))
    end

    -- 2) Remove all 'tool' sections temporarily
    uci:delete_all(common.db.uci.cfg, common.db.uci.sect.tool)
    uci:commit(common.db.uci.cfg)

    -- 3) Rebuild UCI by re-scanning Lua/ucode servers
    local lua_servers = listup_server_candidate(lua_ubus_server_app_dir)
    if lua_servers then
        for _, server_name in ipairs(lua_servers) do
            setup_lua_server_config(server_name)
        end
    end

    local ucode_servers = listup_server_candidate(ucode_ubus_server_app_dir)
    if ucode_servers then
        for _, server_name in ipairs(ucode_servers) do
            setup_ucode_server_config(server_name)
        end
    end

    -- 4) Restore 'enable' to its previous value only for entries that exactly match (do not restore other settings)
    -- Helper function to output the reason for differences
    local function diff_reason(a, b)
        if a.name ~= b.name then return "name" end
        if a.script ~= b.script then return "script" end
        if a.server ~= b.server then return "server" end
        if a.type ~= b.type then return "type" end
        if a.description ~= b.description then return "description" end
        if a.additionalProperties ~= b.additionalProperties then return "additionalProperties" end
        if #a.required ~= #b.required then return "required.length" end
        for i = 1, math.min(#a.required, #b.required) do
            if a.required[i] ~= b.required[i] then return "required["..i.."]" end
        end
        if #a.properties ~= #b.properties then return "properties.length" end
        for i = 1, math.min(#a.properties, #b.properties) do
            if a.properties[i] ~= b.properties[i] then return "properties["..i.."]" end
        end
        return "unknown"
    end

    uci:foreach(common.db.uci.cfg, common.db.uci.sect.tool, function(s)
        if s.name and s.server and s.script then
            local new_def = normalize_from_uci_section(s)
            local key = make_key(new_def)
            local old = old_map[key]
            if not old then
                debug:log("oasis.log", "update_server_info", "no_snapshot key=" .. key)
            else
                if defs_equal(old.def, new_def) then
                    uci:set(common.db.uci.cfg, s[".name"], "enable", old.enable or "0")
                    debug:log("oasis.log", "update_server_info", "restored_enable key=" .. key .. " -> " .. (old.enable or "0"))
                else
                    debug:log("oasis.log", "update_server_info", "mismatch key=" .. key .. " reason=" .. diff_reason(old.def, new_def))
                end
            end
        end
    end)

    -- 5) Check for tool name conflicts
    check_tool_name_conflict()

    -- 6) Final commit
    uci:commit(common.db.uci.cfg)
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

local exec_server_tool = function(format, tool, data)

    local found = false
    local result = {}

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

                    os.execute("sleep 1")
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
            end
        end
    end)

    if not found then
        debug:log("oasis.log", "exec_server_tool", string.format("Tool '%s' not found or not enabled.", tool))
    end

    return result
end

return {
    setup_lua_server_config = setup_lua_server_config,
    setup_ucode_server_config = setup_ucode_server_config,
    update_server_info = update_server_info,
    get_function_call_schema = get_function_call_schema,
    exec_server_tool = exec_server_tool,
}