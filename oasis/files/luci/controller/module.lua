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

module("luci.controller.oasis.module", package.seeall)

function index()

    local is_webui_support = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "webui")

    if not is_webui_support then
        return
    end

    entry({"admin", "network", "oasis"}, firstchild(), "Oasis", 30).dependent=false
    entry({"admin", "network", "oasis", "icons"}, template("oasis/icons"), "Icon", 60).dependent=false
    entry({"admin", "network", "oasis", "tools"}, template("oasis/tools"), "Tools", 50).dependent=false
    entry({"admin", "network", "oasis", "sysmsg"}, template("oasis/sysmsg"), "System Message", 30).dependent=false
    entry({"admin", "network", "oasis", "setting"}, cbi("oasis/setting"), "General Setting", 20).dependent=false
    entry({"admin", "network", "oasis", "chat"}, template("oasis/chat"), "Chat with AI", 10).dependent=false
    entry({"admin", "network", "oasis", "load-chat-data"}, call("load_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "import-chat-data"}, call("import_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "delete-chat-data"}, call("delete_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "rename-chat"}, call("rename"), nil).leaf = true
    entry({"admin", "network", "oasis", "apply-uci-cmd"}, call("apply_uci_cmd"), nil).leaf = true
    entry({"admin", "network", "oasis", "confirm"}, call("confirm"), nil).leaf = true
    entry({"admin", "network", "oasis", "finalize"}, call("finalize"), nil).leaf = true
    entry({"admin", "network", "oasis", "rollback"}, call("rollback"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-sysmsg"}, call("load_sysmsg_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "update-sysmsg"}, call("update_sysmsg_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "add-sysmsg"}, call("add_sysmsg_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "delete-sysmsg"}, call("delete_sysmsg_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-icon-info"}, call("load_icon_info"), nil).leaf = true
    entry({"admin", "network", "oasis", "select-icon"}, call("select_icon"), nil).leaf = true
    entry({"admin", "network", "oasis", "upload-icon-data"}, call("upload_icon_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "delete-icon-data"}, call("delete_icon_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "uci-show"}, call("uci_show"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-extra-sysmsg"}, call("load_extra_sysmsg"), nil).leaf = true
    entry({"admin", "network", "oasis", "select-ai-service"}, call("select_ai_service"), nil).leaf = true
    entry({"admin", "network", "oasis", "base-info"}, call("base_info"), nil).leaf = true
    entry({"admin", "network", "oasis", "change-tool-enable"}, call("change_tool_enable"), nil).leaf = true
    entry({"admin", "network", "oasis", "enable-tool"}, call("enable_tool"), nil).leaf = true
    entry({"admin", "network", "oasis", "disable-tool"}, call("disable_tool"), nil).leaf = true
    entry({"admin", "network", "oasis", "add-remote-mcp-server"}, call("add_remote_mcp_server"), nil).leaf = true
    entry({"admin", "network", "oasis", "remove-remote-mcp-server"}, call("remove_remote_mcp_server"), nil).leaf = true
	entry({"admin", "network", "oasis", "local-tool-info"}, call("local_tool_info"), nil).leaf = true
	entry({"admin", "network", "oasis", "refresh-tools"}, call("refresh_tools"), nil).leaf = true
	entry({"admin", "network", "oasis", "system-reboot"}, call("system_reboot"), nil).leaf = true
	entry({"admin", "network", "oasis", "system-shutdown"}, call("system_shutdown"), nil).leaf = true
	entry({"admin", "network", "oasis", "restart-service"}, call("restart_service"), nil).leaf = true
end

function uci_show_config(target)
    local params = uci:get_all(target) or {}

    print("params:", params)
    print("type:", type(params))

    if type(params) ~= "table" then
        print("not table")
        return {}
    end

    local groups = {}
    local non_anonymous = {}

    for key, options in pairs(params) do
        if options[".anonymous"] == true then
            local t = options[".type"]
            if not groups[t] then groups[t] = {} end
            table.insert(groups[t], options)
        else
            non_anonymous[key] = options
        end
    end

    for _, items in pairs(groups) do
        table.sort(items, function(a, b)
            local nameA = a[".name"] or ""
            local nameB = b[".name"] or ""
            local hexA, hexB = "", ""
            if nameA:sub(1, 3) == "cfg" then
                hexA = nameA:sub(4,5)
            else
                hexA = nameA
            end
            if nameB:sub(1, 3) == "cfg" then
                hexB = nameB:sub(4,5)
            else
                hexB = nameB
            end
            return hexA < hexB
        end)
    end

    local sorted_params = {}

    local group_types = {}
    for t in pairs(groups) do
        table.insert(group_types, t)
    end

    table.sort(group_types)

    for _, sect in ipairs(group_types) do
        local items = groups[sect]
        for i, opt in ipairs(items) do
            for opt_name, value in pairs(opt) do

                local opt_name_sub = opt_name
                 if opt_name_sub:sub(1, 1) == "." then
                    opt_name_sub = opt_name_sub:sub(2)
                end

                if (opt_name == ".type") then
                    sorted_params[#sorted_params + 1]
                    = string.format("%s.@%s[%d]=%s", target, sect, i-1, tostring(value))
                elseif (opt_name ~= ".anonymous") and (opt_name ~= ".index") and (opt_name ~= ".name") then
                    if type(value) == "string" then
                        sorted_params[#sorted_params + 1]
                        = string.format("%s.@%s[%d].%s=%s", target, sect, i-1, opt_name_sub, tostring(value))
                    elseif type(value) == "table" then
                        sorted_params[#sorted_params + 1]
                        = string.format("%s.@%s[%d].%s=", target, sect, i-1, opt_name_sub)
                        for _, list_v in ipairs(value) do
                            sorted_params[#sorted_params]
                            = sorted_params[#sorted_params] .. string.format("%s ", tostring(list_v))
                        end
                    end
                end
            end
        end
    end

    local nonanon_keys = {}
    for key in pairs(non_anonymous) do
        table.insert(nonanon_keys, key)
    end

    table.sort(nonanon_keys)

    for _, sect in ipairs(nonanon_keys) do
        local opt = non_anonymous[sect]
        for opt_name, value in pairs(opt) do
            if opt_name == ".type" then
                sorted_params[#sorted_params + 1]
                = string.format("%s.%s=%s", target, sect, tostring(value))
            elseif (opt_name ~= ".anonymous") and (opt_name ~= ".index") and (opt_name ~= ".name") then
                if type(value) == "string" then
                    sorted_params[#sorted_params + 1]
                    = string.format("%s.%s.%s=%s", target, sect, opt_name, tostring(value))
                elseif type(value) == "table" then
                    sorted_params[#sorted_params + 1]
                    = string.format("%s.%s.%s=", target, sect, opt_name)
                    for _, list_v in ipairs(value) do
                        sorted_params[#sorted_params]
                        = sorted_params[#sorted_params] .. string.format("%s ", tostring(list_v))
                    end
                end
            end
        end
    end

    return sorted_params
end

function load_chat_data()

    -- debug:log("oasis.log", "\n--- [module.lua][load_chat_data] ---")

    local params = luci_http.formvalue("params")

    if not params then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    -- Create a parameter table for ubus call
    local json_param = { id = params }

    local result = util.ubus("oasis.chat", "load", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function import_chat_data()

    -- debug:log("oasis.log", "\n--- [module.lua][import_chat_data] ---")
    local chat_data = luci_http.formvalue("chat_data")

    if not chat_data then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local decoded_chat_data = nixio.bin.b64decode(chat_data)

    local chat_tbl = jsonc.parse(decoded_chat_data)

    if common.check_chat_format(chat_tbl) == false then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "import format error"})
        return
    end

    local id = common.generate_chat_id()

    local conf = datactrl.get_ai_service_cfg(nil, {with_storage = true})
    local file_name = conf.prefix .. id
    local full_file_path = misc.normalize_path(conf.path) .. file_name
    misc.touch(full_file_path)

    local file = io.open(full_file_path, "wb")

    if file then
        file:write(decoded_chat_data)
        file:close()
    else
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "import error"})
        return
    end

    local result = {}
    result.id = id
    result.title = "--"

    local unnamed_section = uci:add(common.db.uci.cfg, common.db.uci.sect.chat)

    uci:set(common.db.uci.cfg, unnamed_section, "id", result.id)
    uci:set(common.db.uci.cfg, unnamed_section, "title", result.title)
    uci:commit(common.db.uci.cfg)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function delete_chat_data()

    -- debug:log("oasis.log", "\n--- [module.lua][delete_chat_data] ---")

    local params = luci_http.formvalue("params")

    if not params then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    -- Create a parameter table for ubus call
    local json_param = { id = params }

    local result = util.ubus("oasis.chat", "delete", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function rename()

    -- debug:log("oasis.log", "\n--- [module.lua][rename] ---")

    local id = luci_http.formvalue("id")
    local title = luci_http.formvalue("title")

    if (not id) or (not title) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local json_param = {id = id, title = title}

    local result = util.ubus("oasis.title", "manual_set", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function apply_uci_cmd()

    -- debug:log("oasis.log", "\n--- [module.lua][apply_uci_cmd] ---")

    local uci_list_json = luci_http.formvalue("uci_list")
    local chat_id = luci_http.formvalue("id")
    local apply_type = luci_http.formvalue("type")

    if (not uci_list_json) or (not chat_id) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    -- debug:log("oasis.log", "chat id = " .. chat_id)
    -- debug:log("oasis.log", "uci_list_json = " .. uci_list_json)

    local uci_list = jsonc.parse(uci_list_json)

    -- initialize flag file for oasisd
    os.remove(common.flag.apply.complete)
    os.remove(common.flag.apply.rollback)

    if apply_type == "commit" then
        oasis.create_new_backup_data(uci_list, chat_id, "normal")
        oasis.apply(uci_list, true) -- true: commit uci config (/etc/config/~)
    else
        oasis.apply(uci_list, false) -- false: save uci config (/tmp/.uci/~)
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json({status = "OK"})
end

function confirm()
    -- debug:log("oasis.log", "\n--- [module.lua][confirm] ---")
    local result = util.ubus("oasis", "confirm")
    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function finalize()

    -- debug:log("oasis.log", "\n--- [module.lua][finalize] ---")
    local out = sys.exec("touch /tmp/oasis/apply/complete;echo $?") or ""
    out = out:gsub("%s+$", "")
    local rc = tonumber(out) or 1

    luci_http.prepare_content("application/json")
    if rc == 0 then
        luci_http.write_json({ status = "OK" })
    else
        luci_http.write_json({ status = "ERROR" })
    end
end

function rollback()
    -- debug:log("oasis.log", "\n--- [module.lua][rollback] ---")
    local out = sys.exec("touch /tmp/oasis/apply/rollback;echo $?") or ""
    out = out:gsub("%s+$", "")
    local rc = tonumber(out) or 1

    luci_http.prepare_content("application/json")
    if rc == 0 then
        luci_http.write_json({ status = "OK" })
    else
        luci_http.write_json({ status = "ERROR" })
    end
end

function load_sysmsg_data()

    -- debug:log("oasis.log", "\n--- [module.lua][load_sysmsg_data] ---")

    local result = util.ubus("oasis", "load_sysmsg_data", {})

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function update_sysmsg_data()

    -- debug:log("oasis.log", "\n--- [module.lua][update_sysmsg_data] ---")

    local target = luci_http.formvalue("target")
    local title = luci_http.formvalue("title")
    local message = luci_http.formvalue("message")

    if (not target) or (not title) or (not message) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local json_param = { target = target, title = title, message = message}

    local result = util.ubus("oasis", "update_sysmsg_data", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function add_sysmsg_data()

    -- debug:log("oasis.log", "\n--- [module.lua][add_sysmsg_data] ---")

    local title = luci_http.formvalue("title")
    local message = luci_http.formvalue("message")

    if (not title) or (not message) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local json_param = { title = title, message = message}

    local result = util.ubus("oasis", "add_sysmsg_data", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function delete_sysmsg_data()

    -- debug:log("oasis.log", "\n--- [module.lua][delete_sysmsg_data] ---")

    local target = luci_http.formvalue("target")

    if not target then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local json_param = { target = target}

    local result = util.ubus("oasis", "delete_sysmsg_data", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function load_icon_info()

    -- debug:log("oasis.log", "\n--- [module.lua][load_icon_info] ---")

    local result = util.ubus("oasis", "load_icon_info", {})

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function select_icon()

    -- debug:log("oasis.log", "\n--- [module.lua][select_icon] ---")
    local using = luci_http.formvalue("using")

    if not using then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local json_param = { using = using }

    local result = util.ubus("oasis", "select_icon", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function upload_icon_data()

    -- debug:log("oasis.log", "\n--- [module.lua][upload_icon_data] ---")
    local filename = luci_http.formvalue("filename")
    local image = luci_http.formvalue("image")

    if (not filename) or (not image) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    -- Validate filename: allow only basename and safe characters + safe extensions (case-insensitive)
    local base = filename:gsub("^.*[/\\]", "")
    local ok_name = base:match("^[A-Za-z0-9._%-]+$")
    local base_l = base:lower()
    local ext = base_l:match("%.([a-z0-9]+)$")
    local allowed = { png=true, jpg=true, jpeg=true, gif=true, webp=true }
    if (not ok_name) or (not ext) or (not allowed[ext]) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Invalid filename" })
        return
    end
    filename = base

    local data = common.load_conf_file("/etc/oasis/oasis.conf")

    local icon_key_suffix
    for icon_key, name in pairs(data.icons) do
        icon_key_suffix = icon_key:match("icon_(%d+)")

        if icon_key_suffix then
            if type(name) == "string" and name:lower() == base_l then
                luci_http.prepare_content("application/json")
                luci_http.write_json({ error = "An image file with the same name already exists" })
                return
            end
        end
    end

    if not icon_key_suffix then
        icon_key_suffix = 0
    end

    local new_icon_key = "icon_" .. (icon_key_suffix + 1)

    data.icons[new_icon_key] = filename

    if not common.update_conf_file("/etc/oasis/oasis.conf", data) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Upload Error" })
        return
    end

    local decoded_icon_img = nixio.bin.b64decode(image)

    local file = io.open(data.icons.path .. filename, "wb")

    if file then
        file:write(decoded_icon_img)
        file:close()
        luci_http.prepare_content("application/json")
        luci_http.write_json({ key = new_icon_key })
        return
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json({ error = "Upload Error" })
end

function delete_icon_data()

    -- debug:log("oasis.log", "\n--- [module.lua][delete_icon_data] ---")
    local icon_key = luci_http.formvalue("key")

    if not icon_key then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local data = common.load_conf_file("/etc/oasis/oasis.conf")

    if (not data.icons[icon_key]) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "No icon data" })
        return
    end

    local filename = data.icons[icon_key]

    os.remove(data.icons.path .. filename)

    data.icons[icon_key] = nil

    -- If the deleted icon was selected, fallback to another available icon key
    if data.icons.using == icon_key then
        local fallback = ""
        for k, v in pairs(data.icons) do
            if type(k) == "string" and k:match("^icon_%d+$") and type(v) == "string" and #v > 0 then
                fallback = k
                break
            end
        end
        data.icons.using = fallback
    end

    if not common.update_conf_file("/etc/oasis/oasis.conf", data) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Failed to delete icon info" })
        return
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json({status = "OK"})
end

function uci_show()

    -- debug:log("oasis.log", "\n--- [module.lua][uci_show] ---")
    local target = luci_http.formvalue("target")

    local list = util.ubus("uci", "configs", {})
    local hit = false

    -- validation of uci config name --
    for _, config in ipairs(list.configs) do
        if target == config then
            hit = true
            break
        end
    end

    if not hit then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Not Found" })
        return
    end

    -- uci show --
    local result = uci_show_config(target)

    if (#result == 0) or (result == nil) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Not Found" })
        return
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function load_extra_sysmsg()

    -- debug:log("oasis.log", "\n--- [module.lua][load_extra_sysmsg] ---")
    local url = luci_http.formvalue("url")

    if (#url == 0) or (url == nil) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Not Found" })
        return
    end

    local contents = {}
    transfer.get_to_server(url, function(chunk)
        contents.sysmsg = chunk
    end)

    luci_http.prepare_content("application/json")
    luci_http.write_json(contents)
end

function select_ai_service()

    -- debug:log("oasis.log", "\n--- [module.lua][select_ai_service] ---")

    local identifier    = luci_http.formvalue("identifier")
    local name          = luci_http.formvalue("name")
    local model         = luci_http.formvalue("model")

    -- debug:log("oasis.log", "identifier = " .. identifier)
    -- debug:log("oasis.log", "name = " .. name)
    -- debug:log("oasis.log", "model = " .. model)

    local target_uid = ""
    local data = uci:get_all(common.db.uci.cfg);

    if not data then
        luci_http.prepare_content("application/json")
        luci_http.write_json({error = "Failed to load config"})
        return
    end

    for _, tbl in pairs(data) do
        for key, value in pairs(tbl) do
            if (key == ".type") and (value == "service") then
                local uid = tbl[".name"]
                if (data[uid].identifier == identifier) and (data[uid].name == name) and (data[uid].model == model) then
                    target_uid = uid
                    break
                end
            end
        end

        if target_uid ~= "" then
            break
        end
    end

    -- debug:log("oasis.log", "target_uid = " .. target_uid)

    if target_uid == "" then
        luci_http.prepare_content("application/json")
        luci_http.write_json({error = "Not Found"})
        return
    end

    uci:reorder(common.db.uci.cfg, target_uid, 1)
    uci:commit(common.db.uci.cfg)

    luci_http.prepare_content("application/json")
    luci_http.write_json({status = "OK"})
end

function base_info()
    local info_tbl = {}
    info_tbl.icon = oasis_ubus.retrieve_icon_info("/etc/oasis/oasis.conf", "table")
    info_tbl.sysmsg = oasis_ubus.retrieve_sysmsg_info("/etc/oasis/oasis.conf", "table")
    info_tbl.chat = oasis_ubus.retrieve_chat_info("table")
    info_tbl.service = oasis_ubus.retrieve_service_info("table")
    info_tbl.configs = oasis_ubus.retrieve_uci_config("table")
    luci_http.prepare_content("application/json")
    luci_http.write_json(info_tbl)
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

function system_reboot()
    -- Handle cancel: remove pending reboot flag and return OK
    local cancel = luci_http.formvalue("cancel")
    if cancel == "1" or cancel == "true" then
        os.remove(common.file.console.reboot_required)
        luci_http.prepare_content("application/json")
        luci_http.write_json({ status = "OK", canceled = true })
        return
    end

    local is_support = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")

    if not is_support then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ status = "NG" })
        return
    end
    local cmd = require("oasis.local.tool.system.command")
    cmd.system_reboot_after_5sec()

    luci_http.prepare_content("application/json")
    luci_http.write_json({ status = "OK" })
end

function system_shutdown()
    -- Handle cancel: remove pending shutdown flag and return OK
    local cancel = luci_http.formvalue("cancel")
    if cancel == "1" or cancel == "true" then
        os.remove(common.file.console.shutdown_required)
        luci_http.prepare_content("application/json")
        luci_http.write_json({ status = "OK", canceled = true })
        return
    end

    local is_support = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "local_tool")

    if not is_support then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ status = "NG" })
        return
    end
    local cmd = require("oasis.local.tool.system.command")
    cmd.system_shutdown_after_5sec()

    luci_http.prepare_content("application/json")
    luci_http.write_json({ status = "OK" })
end

function restart_service()
	-- Handle cancel: remove pending service restart flag and return OK
	local cancel = luci_http.formvalue("cancel")
	if cancel == "1" or cancel == "true" then
		os.remove(common.file.service.restart_required)
		luci_http.prepare_content("application/json")
		luci_http.write_json({ status = "OK", canceled = true })
		return
	end

	local path = common.file.service.restart_required
	if not misc.check_file_exist(path) then
		luci_http.prepare_content("application/json")
		luci_http.write_json({ status = "NG" })
		return
	end

	local svc = misc.read_file(path)
	if not svc or #svc == 0 then
		luci_http.prepare_content("application/json")
		luci_http.write_json({ status = "NG" })
		return
	end

	svc = svc:gsub("%s+$", "")

	local cmd = require("oasis.local.tool.system.command")
	cmd.restart_service_after_3sec(svc)

	luci_http.prepare_content("application/json")
	luci_http.write_json({ status = "OK" })
end
