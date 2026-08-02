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
local nixio_fs      = require("nixio.fs")
local oasis_ubus    = require("oasis.ubus.util")

module("luci.controller.oasis.module", package.seeall)

function index()

    local is_webui_support = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "webui")

    if not is_webui_support then
        return
    end

    entry({"admin", "network", "oasis"}, firstchild(), "Oasis", 30).dependent=false
    entry({"admin", "network", "oasis", "icons"}, template("oasis/icons"), "Icon", 60).dependent=false
    entry({"admin", "network", "oasis", "sysmsg"}, template("oasis/sysmsg"), "System Message", 30).dependent=false
    entry({"admin", "network", "oasis", "setting"}, template("oasis/setting-v2"), "General Setting", 20).dependent=false
    entry(
        {"admin", "network", "oasis", "setting-v2"},
        alias("admin", "network", "oasis", "setting"),
        nil
    ).dependent=false
    entry({"admin", "network", "oasis", "load-settings"}, call("load_settings"), nil).leaf = true
    local update_settings_entry = entry({"admin", "network", "oasis", "update-settings"}, post("update_settings"), nil)
    update_settings_entry.leaf = true
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

-- General Setting JSON API -------------------------------------------------
--
-- Keep this API in the authenticated LuCI controller instead of exposing a
-- separate rpcd object.  The update route uses LuCI's post() action, so
-- LuCI enforces both POST and the current session's CSRF token before this
-- function is dispatched.

local SETTINGS_CONFIG = "oasis"
local SETTINGS_CONFIG_PATH = "/etc/config/oasis"
local SETTINGS_LOCK_PATH = "/var/lock/oasis-settings.lock"
local SETTINGS_ASSIST_FILTER = "/usr/lib/lua/oasis/chat/filter.lua"
local SETTINGS_ROLLBACK_DAEMON = "/usr/bin/oasisd"
local SETTINGS_MAX_PAYLOAD = 524288
local SETTINGS_MAX_REQUEST = 2097152
local SETTINGS_MAX_SERVICES = 32
local SETTINGS_MAX_IDENTIFIER = 64
local SETTINGS_MAX_PROVIDER = 64
local SETTINGS_MAX_MODEL = 256
local SETTINGS_MAX_STORAGE_PATH = 512
local SETTINGS_MAX_ENDPOINT = 2048
local SETTINGS_MAX_API_KEY = 8192
local SETTINGS_MAX_TOKEN_LENGTH = 12
local SETTINGS_MIN_THINKING_BUDGET = 1024

local SETTINGS_PROVIDERS = {
    ["Ollama"] = true,
    ["OpenAI"] = true,
    ["Anthropic"] = true,
    ["Gemini"] = true,
    ["OpenRouter"] = true,
    ["LM Studio"] = true
}

local SETTINGS_ENDPOINT_OPTIONS = {
    OpenAI = {
        type = "openai_endpoint_type",
        custom = "openai_custom_endpoint"
    },
    Anthropic = {
        type = "anthropic_endpoint_type",
        custom = "anthropic_custom_endpoint"
    },
    Gemini = {
        type = "gemini_endpoint_type",
        custom = "gemini_custom_endpoint"
    },
    OpenRouter = {
        type = "openrouter_endpoint_type",
        custom = "openrouter_custom_endpoint"
    }
}

local SETTINGS_KNOWN_SERVICE_OPTIONS = {
    "identifier", "name", "model", "api_key", "function_calling",
    "show_thinking", "ollama_endpoint", "openai_endpoint_type",
    "openai_custom_endpoint", "openai_api_mode",
    "anthropic_endpoint_type", "anthropic_custom_endpoint", "max_tokens",
    "thinking", "type", "budget_tokens", "gemini_endpoint_type",
    "gemini_custom_endpoint", "openrouter_endpoint_type",
    "openrouter_custom_endpoint", "lmstudio_endpoint"
}

local SETTINGS_COMMON_KNOWN_OPTIONS = {
    "identifier", "name", "model", "api_key", "function_calling",
    "show_thinking"
}

local SETTINGS_COMMON_SERVICE_FIELDS = {
    identifier = true,
    name = true,
    model = true,
    function_calling = true,
    show_thinking = true,
    api_key_action = true,
    api_key = true
}

local SETTINGS_GENERAL_FIELDS = {
    assist_enable = true,
    rpc_enable = true,
    storage_path = true,
    chat_max = true,
    rollback_enable = true,
    rollback_time = true
}

local function settings_has_own(tbl, key)
    return type(tbl) == "table" and rawget(tbl, key) ~= nil
end

local function settings_string_option(section, option, fallback)
    local value = type(section) == "table" and section[option] or nil
    if type(value) == "string" then
        return value
    end
    return fallback
end

local function settings_trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return value:match("^%s*(.-)%s*$") or ""
end

local function settings_has_control(value)
    return type(value) == "string" and value:find("[%z\1-\31\127]") ~= nil
end

local function settings_file_exists(path)
    local stat = nixio_fs.stat(path)
    return stat ~= nil and stat.type == "reg"
end

local function settings_checksum(value)
    -- Adler-32 is sufficient here: this is a stale-write detector, not an
    -- authentication primitive.  Keeping it in Lua avoids a crypto module or
    -- shell-command dependency, and the raw configuration is never exposed.
    local a = 1
    local b = 0
    for index = 1, #value do
        a = (a + value:byte(index)) % 65521
        b = (b + a) % 65521
    end
    -- Format each 16-bit half independently.  On 32-bit targets, passing the
    -- combined unsigned value through Lua's integer formatter may overflow.
    return string.format("%04x%04x", b, a)
end

local function settings_canonical(value)
    local value_type = type(value)
    if value_type == "string" then
        return "s" .. #value .. ":" .. value
    elseif value_type == "number" then
        return "n" .. tostring(value)
    elseif value_type == "boolean" then
        return value and "b1" or "b0"
    elseif value_type ~= "table" then
        return "z"
    end

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        local left_key = type(left) .. ":" .. tostring(left)
        local right_key = type(right) .. ":" .. tostring(right)
        return left_key < right_key
    end)

    local parts = { "t", tostring(#keys), ":" }
    for _, key in ipairs(keys) do
        parts[#parts + 1] = settings_canonical(key)
        parts[#parts + 1] = settings_canonical(value[key])
    end
    return table.concat(parts)
end

local function settings_file_metadata()
    local stat = nixio_fs.stat(SETTINGS_CONFIG_PATH)
    if not stat or stat.type ~= "reg" then
        return nil
    end
    return string.format(
        "%s:%s:%s:%s",
        tostring(stat.mtime or 0),
        tostring(stat.ctime or 0),
        tostring(stat.ino or 0),
        tostring(stat.size or 0)
    )
end

local function settings_revision(public_data, metadata)
    metadata = metadata or settings_file_metadata()
    if type(public_data) ~= "table" or not metadata then
        return nil
    end
    return "v2:" .. settings_checksum(settings_canonical(public_data))
        .. ":" .. metadata
end

local function settings_error(code, message, fields)
    return {
        ok = false,
        error = {
            code = code,
            message = message,
            fields = fields or {}
        }
    }
end

local function settings_write_json(value, status, status_message)
    if status then
        luci_http.status(status, status_message)
    end
    luci_http.prepare_content("application/json")
    luci_http.write_json(value)
end

local function settings_add_error(errors, path, message)
    if errors[path] == nil then
        errors[path] = message
    end
end

local function settings_reject_unknown(value, allowed, path, errors)
    if type(value) ~= "table" then
        return
    end
    for key in pairs(value) do
        if allowed[key] ~= true then
            settings_add_error(
                errors,
                path,
                "One or more unsupported fields were supplied."
            )
            return
        end
    end
end

local function settings_endpoint_type(section, type_option, custom_option)
    local value = settings_string_option(section, type_option, "")
    if value == "default" or value == "custom" then
        return value
    end
    return #settings_string_option(section, custom_option, "") > 0
        and "custom" or "default"
end

local function settings_service_from_section(section, active)
    local provider = settings_string_option(section, "name", "")
    local service = {
        identifier = settings_string_option(section, "identifier", ""),
        name = provider,
        model = settings_string_option(section, "model", ""),
        function_calling = settings_string_option(section, "function_calling", "0"),
        show_thinking = settings_string_option(section, "show_thinking", "0"),
        api_key_set = #settings_string_option(section, "api_key", "") > 0,
        active = active
    }

    if provider == "Ollama" then
        service.ollama_endpoint = settings_string_option(section, "ollama_endpoint", "")
    elseif provider == "OpenAI" then
        local mode = settings_string_option(section, "openai_api_mode", "")
        if mode ~= "responses" and mode ~= "chat_completions" then
            mode = "chat_completions"
        end
        service.openai_endpoint_type = settings_endpoint_type(
            section, "openai_endpoint_type", "openai_custom_endpoint"
        )
        service.openai_custom_endpoint = settings_string_option(
            section, "openai_custom_endpoint", ""
        )
        service.openai_api_mode = mode
    elseif provider == "Anthropic" then
        local thinking = settings_string_option(section, "thinking", "")
        if thinking == "" then
            thinking = settings_string_option(section, "type", "disabled")
        end
        service.anthropic_endpoint_type = settings_endpoint_type(
            section, "anthropic_endpoint_type", "anthropic_custom_endpoint"
        )
        service.anthropic_custom_endpoint = settings_string_option(
            section, "anthropic_custom_endpoint", ""
        )
        service.max_tokens = settings_string_option(section, "max_tokens", "1024")
        service.thinking = thinking
        service.budget_tokens = settings_string_option(section, "budget_tokens", "")
    elseif provider == "Gemini" then
        service.gemini_endpoint_type = settings_endpoint_type(
            section, "gemini_endpoint_type", "gemini_custom_endpoint"
        )
        service.gemini_custom_endpoint = settings_string_option(
            section, "gemini_custom_endpoint", ""
        )
    elseif provider == "OpenRouter" then
        service.openrouter_endpoint_type = settings_endpoint_type(
            section, "openrouter_endpoint_type", "openrouter_custom_endpoint"
        )
        service.openrouter_custom_endpoint = settings_string_option(
            section, "openrouter_custom_endpoint", ""
        )
    elseif provider == "LM Studio" then
        service.lmstudio_endpoint = settings_string_option(
            section, "lmstudio_endpoint", ""
        )
    end

    return service
end

local function settings_legacy_identifier(section_name, reserved)
    local prefix = "legacy-" .. settings_checksum(section_name)
    for attempt = 0, 63 do
        local identifier = attempt == 0 and prefix or (prefix .. "-" .. attempt)
        if not reserved[identifier] then
            reserved[identifier] = true
            return identifier
        end
    end
    return nil
end

local function settings_read_configuration()
    if not settings_file_exists(SETTINGS_CONFIG_PATH) then
        return nil
    end

    local read_failed = false
    local function read_option(section, option, fallback)
        local value, err = uci:get(SETTINGS_CONFIG, section, option)
        if type(value) == "string" then
            return value
        end
        if value == nil or (value == false
            and (err == "Entry not found" or err == "No data")) then
            return fallback
        end
        read_failed = true
        return fallback
    end

    local capabilities = {
        assist = settings_file_exists(SETTINGS_ASSIST_FILTER),
        rollback = settings_file_exists(SETTINGS_ROLLBACK_DAEMON)
    }
    local settings = {
        rpc_enable = read_option("rpc", "enable", "0"),
        storage_path = read_option(
            "storage", "path", "/etc/oasis/chat_data"
        ),
        chat_max = read_option("storage", "chat_max", "30"),
        rollback_enable = read_option("rollback", "enable", "1"),
        rollback_time = read_option("rollback", "time", "300")
    }
    if capabilities.assist then
        settings.assist_enable = read_option("assist", "enable", "0")
    end
    if read_failed then
        return nil
    end

    local raw_services = {}
    local identifier_counts = {}
    local reserved = {}
    local service_sections = {}
    local active = true
    local ok, foreach_error = uci:foreach(SETTINGS_CONFIG, "service", function(section)
        local identifier = settings_string_option(section, "identifier", "")
        local name = settings_string_option(section, ".name", "")
        raw_services[#raw_services + 1] = {
            identifier = identifier,
            section = name,
            provider = settings_string_option(section, "name", ""),
            api_key = settings_string_option(section, "api_key", ""),
            public_service = settings_service_from_section(section, active)
        }
        service_sections[#service_sections + 1] = name
        active = false
        if identifier ~= "" then
            identifier_counts[identifier] = (identifier_counts[identifier] or 0) + 1
            reserved[identifier] = true
        end
    end)
    -- Depending on the rpcd/LuCI version, an empty filtered result is reported
    -- as false with no error, "No data", or "Entry not found".  All three are
    -- valid before the first service is added.
    if not ok and foreach_error
        and foreach_error ~= "No data"
        and foreach_error ~= "Entry not found" then
        return nil
    end

    local services = {}
    local existing = {}
    for _, raw in ipairs(raw_services) do
        local stored = raw.identifier
        local legacy = stored == ""
            or #stored > SETTINGS_MAX_IDENTIFIER
            or settings_trim(stored) ~= stored
            or settings_has_control(stored)
            or identifier_counts[stored] ~= 1
        local public_identifier = stored
        if legacy then
            public_identifier = settings_legacy_identifier(raw.section, reserved)
        end
        if not public_identifier then
            return nil
        end
        raw.public_service.identifier = public_identifier
        services[#services + 1] = raw.public_service
        existing[public_identifier] = {
            section = raw.section,
            provider = raw.provider,
            api_key = raw.api_key,
            legacy = legacy
        }
    end

    return {
        public_data = {
            schema_version = 1,
            capabilities = capabilities,
            settings = settings,
            services = services
        },
        existing = existing,
        service_sections = service_sections,
        reserved_identifiers = reserved
    }
end

local function settings_read_stable()
    for _ = 1, 3 do
        local before = settings_file_metadata()
        local state = settings_read_configuration()
        local after = settings_file_metadata()
        if before and before == after and state then
            local revision = settings_revision(state.public_data, after)
            if revision then
                return state, revision
            end
        end
    end
    return nil, nil
end

local function settings_snapshot(state, revision)
    state.public_data.revision = revision
    return state.public_data
end

local function settings_normalized_flag(value, path, errors)
    if type(value) ~= "string" or (value ~= "0" and value ~= "1") then
        settings_add_error(errors, path, "Select either enabled or disabled.")
        return nil
    end
    return value
end

local function settings_positive_integer(value, path, errors)
    if type(value) ~= "string"
        or value == ""
        or #value > SETTINGS_MAX_TOKEN_LENGTH
        or not value:match("^%d+$") then
        settings_add_error(errors, path, "Enter a positive integer.")
        return nil
    end
    local normalized = value:gsub("^0+", "")
    if normalized == "" then
        normalized = "0"
    end
    local number = tonumber(normalized)
    if not number or number <= 0 or number ~= math.floor(number) then
        settings_add_error(errors, path, "Enter a positive integer.")
        return nil
    end
    return { text = normalized, number = number }
end

local function settings_required_text(value, path, max_length, errors)
    if type(value) ~= "string" then
        settings_add_error(errors, path, "This field is required.")
        return nil
    end
    local normalized = settings_trim(value)
    if normalized == "" then
        settings_add_error(errors, path, "This field is required.")
        return nil
    end
    if #normalized > max_length then
        settings_add_error(errors, path, "The value is too long.")
        return nil
    end
    if settings_has_control(normalized) then
        settings_add_error(errors, path, "Control characters are not allowed.")
        return nil
    end
    return normalized
end

local function settings_valid_port(port)
    if port == nil then
        return true
    end
    local number = tonumber(port)
    return #port <= 5 and number ~= nil and number >= 1 and number <= 65535
end

local function settings_valid_ipv4(value)
    if not value:match("^%d+%.%d+%.%d+%.%d+$") then
        return false
    end

    local parts = {}
    for part in value:gmatch("[^.]+") do
        parts[#parts + 1] = part
    end
    if #parts ~= 4 or value:sub(1, 1) == "." or value:sub(-1) == "." then
        return false
    end
    for _, part in ipairs(parts) do
        if #part > 3 or not part:match("^%d+$") or tonumber(part) > 255 then
            return false
        end
    end
    return true
end

local function settings_ipv6_group_count(value, allow_ipv4_tail)
    if value == "" then
        return 0
    end
    if value:sub(1, 1) == ":" or value:sub(-1) == ":" then
        return -1
    end
    local groups = {}
    for group in value:gmatch("[^:]+") do
        groups[#groups + 1] = group
    end
    local count = 0
    for index, group in ipairs(groups) do
        if group:find(".", 1, true) then
            if not allow_ipv4_tail
                or index ~= #groups
                or not settings_valid_ipv4(group) then
                return -1
            end
            count = count + 2
        else
            if not group:match("^[0-9A-Fa-f]+$") or #group > 4 then
                return -1
            end
            count = count + 1
        end
    end
    return count
end

local function settings_valid_ipv6(value)
    local compressed = value:find("::", 1, true)
    if not compressed then
        return settings_ipv6_group_count(value, true) == 8
    end
    if value:find("::", compressed + 2, true) then
        return false
    end
    local left = value:sub(1, compressed - 1)
    local right = value:sub(compressed + 2)
    local left_count = settings_ipv6_group_count(left, false)
    local right_count = settings_ipv6_group_count(right, true)
    return left_count >= 0 and right_count >= 0
        and left_count + right_count < 8
end

local function settings_valid_url(value)
    if value:find("[%s\\]") or value:find("@", 1, true) then
        return false
    end
    local scheme, authority = value:match("^(%a+)://([^/%?#]+)")
    if not scheme or (scheme:lower() ~= "http" and scheme:lower() ~= "https") then
        return false
    end
    if not authority or authority == "" then
        return false
    end

    local host, port
    if authority:sub(1, 1) == "[" then
        host, port = authority:match("^%[([0-9A-Fa-f:%.]+)%]:(%d+)$")
        if not host then
            host = authority:match("^%[([0-9A-Fa-f:%.]+)%]$")
        end
        if not host or not settings_valid_ipv6(host) then
            return false
        end
    else
        host, port = authority:match("^([^:]+):(%d+)$")
        if not host then
            if authority:find(":", 1, true) then
                return false
            end
            host = authority
        end
        if not host:match("^[%w_.%-]+$")
            or not host:match("[%w]")
            or host:match("^%.")
            or host:find("..", 1, true)
            or host:sub(1, 1) == "-"
            or host:sub(-1) == "-"
            or host:find(".-", 1, true)
            or host:find("-.", 1, true) then
            return false
        end
    end
    return settings_valid_port(port)
end

local function settings_normalized_url(value, path, errors)
    local normalized = settings_required_text(
        value, path, SETTINGS_MAX_ENDPOINT, errors
    )
    if normalized and not settings_valid_url(normalized) then
        settings_add_error(errors, path, "Enter a valid HTTP or HTTPS URL.")
        return nil
    end
    return normalized
end

local function settings_normalized_enum(value, allowed, path, errors)
    if type(value) ~= "string" or allowed[value] ~= true then
        settings_add_error(errors, path, "Select a supported value.")
        return nil
    end
    return value
end

local function settings_generate_identifier(reserved)
    for _ = 1, 8 do
        local random = nixio_fs.readfile("/dev/urandom", 16)
        if type(random) == "string" and #random >= 10 then
            local digits = {}
            for index = 1, 10 do
                digits[index] = tostring(random:byte(index) % 10)
            end
            local identifier = table.concat(digits)
            if not reserved[identifier] then
                reserved[identifier] = true
                return identifier
            end
        end
    end
    return nil
end

local function settings_validate_general(value, capabilities, errors)
    local normalized = {}
    if type(value) ~= "table" then
        settings_add_error(errors, "settings", "Settings must be an object.")
        return normalized
    end
    settings_reject_unknown(value, SETTINGS_GENERAL_FIELDS, "settings", errors)

    if settings_has_own(value, "assist_enable") then
        if not capabilities.assist then
            settings_add_error(
                errors, "settings.assist_enable",
                "AI-assisted configuration is unavailable."
            )
        else
            normalized.assist_enable = settings_normalized_flag(
                value.assist_enable, "settings.assist_enable", errors
            )
        end
    end
    if settings_has_own(value, "rpc_enable") then
        normalized.rpc_enable = settings_normalized_flag(
            value.rpc_enable, "settings.rpc_enable", errors
        )
    end
    if settings_has_own(value, "storage_path") then
        local path = settings_required_text(
            value.storage_path, "settings.storage_path",
            SETTINGS_MAX_STORAGE_PATH, errors
        )
        if path then
            if path:sub(1, 1) ~= "/" then
                settings_add_error(
                    errors, "settings.storage_path",
                    "Enter an absolute path beginning with a slash."
                )
            else
                local has_parent_segment = false
                for segment in path:gmatch("[^/]+") do
                    if segment == ".." then
                        has_parent_segment = true
                        break
                    end
                end
                if has_parent_segment then
                    settings_add_error(
                        errors, "settings.storage_path",
                        "The storage path must not contain parent directory segments."
                    )
                else
                    normalized.storage_path = path
                end
            end
        end
    end
    if settings_has_own(value, "chat_max") then
        local parsed = settings_positive_integer(
            value.chat_max, "settings.chat_max", errors
        )
        if parsed then
            if parsed.number < 10 or parsed.number > 100
                or parsed.number % 10 ~= 0 then
                settings_add_error(
                    errors, "settings.chat_max",
                    "Select a value from 10 to 100 in steps of 10."
                )
            else
                normalized.chat_max = parsed.text
            end
        end
    end
    if settings_has_own(value, "rollback_enable") then
        if not capabilities.rollback then
            settings_add_error(
                errors, "settings.rollback_enable",
                "Rollback settings are unavailable."
            )
        else
            normalized.rollback_enable = settings_normalized_flag(
                value.rollback_enable, "settings.rollback_enable", errors
            )
        end
    end
    if settings_has_own(value, "rollback_time") then
        if not capabilities.rollback then
            settings_add_error(
                errors, "settings.rollback_time",
                "Rollback settings are unavailable."
            )
        else
            local parsed = settings_positive_integer(
                value.rollback_time, "settings.rollback_time", errors
            )
            if parsed then
                if parsed.number < 60 or parsed.number > 600
                    or parsed.number % 60 ~= 0 then
                    settings_add_error(
                        errors, "settings.rollback_time",
                        "Select a value from 60 to 600 seconds in steps of 60."
                    )
                else
                    normalized.rollback_time = parsed.text
                end
            end
        end
    end
    return normalized
end

local function settings_service_allowed_fields(provider)
    local allowed = {}
    for key in pairs(SETTINGS_COMMON_SERVICE_FIELDS) do
        allowed[key] = true
    end
    if provider == "Ollama" then
        allowed.ollama_endpoint = true
    elseif provider == "OpenAI" then
        allowed.openai_endpoint_type = true
        allowed.openai_custom_endpoint = true
        allowed.openai_api_mode = true
    elseif provider == "Anthropic" then
        allowed.anthropic_endpoint_type = true
        allowed.anthropic_custom_endpoint = true
        allowed.max_tokens = true
        allowed.thinking = true
        allowed.budget_tokens = true
    elseif provider == "Gemini" then
        allowed.gemini_endpoint_type = true
        allowed.gemini_custom_endpoint = true
    elseif provider == "OpenRouter" then
        allowed.openrouter_endpoint_type = true
        allowed.openrouter_custom_endpoint = true
    elseif provider == "LM Studio" then
        allowed.lmstudio_endpoint = true
    end
    return allowed
end

local function settings_validate_endpoint_options(
    service, normalized, provider, prefix, errors
)
    local options = SETTINGS_ENDPOINT_OPTIONS[provider]
    if not options then
        return
    end
    local selected = settings_normalized_enum(
        service[options.type], { default = true, custom = true },
        prefix .. options.type, errors
    )
    if not selected then
        return
    end
    normalized[options.type] = selected
    if selected == "custom" then
        normalized[options.custom] = settings_normalized_url(
            service[options.custom], prefix .. options.custom, errors
        )
    end
end

local function settings_validate_api_key(
    service, normalized, existing, provider, prefix, errors
)
    local action = settings_normalized_enum(
        service.api_key_action,
        { keep = true, replace = true, clear = true },
        prefix .. "api_key_action", errors
    )
    if not action then
        return
    end
    normalized.api_key_action = action
    if action ~= "replace" and settings_has_own(service, "api_key") then
        settings_add_error(
            errors, prefix .. "api_key",
            "A new API key is accepted only when replacing the stored key."
        )
    end
    if action == "keep" then
        if existing and existing.api_key ~= "" and existing.provider ~= provider then
            settings_add_error(
                errors, prefix .. "api_key_action",
                "Choose Replace with a new key or Clear stored key after changing the provider."
            )
        else
            normalized._api_key = existing and existing.api_key or ""
        end
        return
    end
    if action == "clear" then
        normalized._api_key = ""
        return
    end
    local api_key = service.api_key
    if type(api_key) ~= "string" then
        settings_add_error(errors, prefix .. "api_key", "The API key must be a string.")
    elseif #api_key > SETTINGS_MAX_API_KEY then
        settings_add_error(errors, prefix .. "api_key", "The value is too long.")
    elseif settings_has_control(api_key) then
        settings_add_error(
            errors, prefix .. "api_key", "Control characters are not allowed."
        )
    else
        normalized._api_key = api_key
    end
end

local function settings_validate_service(
    service, zero_index, state, reserved, used_sections, errors
)
    local prefix = "services." .. zero_index .. "."
    local normalized = {}
    if type(service) ~= "table" then
        settings_add_error(
            errors, "services." .. zero_index,
            "Each service must be an object."
        )
        return normalized
    end

    local identifier
    if type(service.identifier) ~= "string" then
        settings_add_error(
            errors, prefix .. "identifier", "The identifier must be a string."
        )
    else
        identifier = settings_trim(service.identifier)
        if #identifier > SETTINGS_MAX_IDENTIFIER or settings_has_control(identifier) then
            settings_add_error(errors, prefix .. "identifier", "The value is invalid.")
            identifier = nil
        end
    end

    local existing
    if identifier and identifier ~= "" then
        existing = state.existing[identifier]
        if not existing then
            settings_add_error(
                errors, prefix .. "identifier",
                "The service identifier is unknown or no longer exists."
            )
        elseif used_sections[existing.section] then
            settings_add_error(
                errors, prefix .. "identifier",
                "Each service identifier must be unique."
            )
        else
            used_sections[existing.section] = true
            normalized._section = existing.section
            if existing.legacy then
                identifier = settings_generate_identifier(reserved)
                if not identifier then
                    settings_add_error(
                        errors, prefix .. "identifier",
                        "Could not allocate an identifier."
                    )
                end
            end
        end
    elseif identifier then
        identifier = settings_generate_identifier(reserved)
        if not identifier then
            settings_add_error(
                errors, prefix .. "identifier", "Could not allocate an identifier."
            )
        end
    end
    if identifier then
        normalized.identifier = identifier
    end

    local provider = settings_required_text(
        service.name, prefix .. "name", SETTINGS_MAX_PROVIDER, errors
    )
    local unsupported = false
    if provider and not SETTINGS_PROVIDERS[provider] then
        if existing and provider == existing.provider then
            unsupported = true
        else
            settings_add_error(
                errors, prefix .. "name", "Select a supported provider."
            )
            provider = nil
        end
    end
    settings_reject_unknown(
        service, settings_service_allowed_fields(provider),
        "services." .. zero_index, errors
    )
    if provider then
        normalized.name = provider
        normalized._unsupported_provider = unsupported
    end

    normalized.model = settings_required_text(
        service.model, prefix .. "model", SETTINGS_MAX_MODEL, errors
    )
    normalized.function_calling = settings_normalized_flag(
        service.function_calling, prefix .. "function_calling", errors
    )
    normalized.show_thinking = settings_normalized_flag(
        service.show_thinking, prefix .. "show_thinking", errors
    )

    if provider == "Ollama" then
        normalized.ollama_endpoint = settings_normalized_url(
            service.ollama_endpoint, prefix .. "ollama_endpoint", errors
        )
    elseif provider == "LM Studio" then
        normalized.lmstudio_endpoint = settings_normalized_url(
            service.lmstudio_endpoint, prefix .. "lmstudio_endpoint", errors
        )
    elseif provider then
        settings_validate_endpoint_options(
            service, normalized, provider, prefix, errors
        )
    end

    if provider == "OpenAI" then
        normalized.openai_api_mode = settings_normalized_enum(
            service.openai_api_mode,
            { responses = true, chat_completions = true },
            prefix .. "openai_api_mode", errors
        )
    elseif provider == "Anthropic" then
        local max_tokens = settings_positive_integer(
            service.max_tokens, prefix .. "max_tokens", errors
        )
        local thinking = settings_normalized_enum(
            service.thinking,
            { disabled = true, enabled = true, adaptive = true },
            prefix .. "thinking", errors
        )
        if max_tokens then
            normalized.max_tokens = max_tokens.text
        end
        if thinking then
            normalized.thinking = thinking
        end
        if thinking == "enabled" then
            local budget = settings_positive_integer(
                service.budget_tokens, prefix .. "budget_tokens", errors
            )
            if budget then
                if budget.number < SETTINGS_MIN_THINKING_BUDGET then
                    settings_add_error(
                        errors, prefix .. "budget_tokens",
                        "Budget Tokens must be at least 1024."
                    )
                elseif max_tokens and budget.number >= max_tokens.number then
                    settings_add_error(
                        errors, prefix .. "budget_tokens",
                        "Budget Tokens must be less than Max Tokens."
                    )
                else
                    normalized.budget_tokens = budget.text
                end
            end
        elseif settings_has_own(service, "budget_tokens") then
            settings_add_error(
                errors, prefix .. "budget_tokens",
                "Budget Tokens are accepted only for manual thinking."
            )
        end
    end

    if provider then
        settings_validate_api_key(
            service, normalized, existing, provider, prefix, errors
        )
    end
    return normalized
end

local function settings_is_array(value)
    if type(value) ~= "table" then
        return false
    end
    local count = 0
    local maximum = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return false
        end
        count = count + 1
        if key > maximum then
            maximum = key
        end
    end
    return count == maximum
end

local function settings_validate_request(args, state)
    local errors = {}
    local normalized = {
        settings = settings_validate_general(
            args.settings, state.public_data.capabilities, errors
        ),
        services = {}
    }
    if not settings_is_array(args.services) then
        settings_add_error(errors, "services", "Services must be an array.")
        return normalized, errors
    end
    if #args.services > SETTINGS_MAX_SERVICES then
        settings_add_error(
            errors, "services", "No more than 32 services may be configured."
        )
        return normalized, errors
    end

    local reserved = {}
    for identifier in pairs(state.reserved_identifiers) do
        reserved[identifier] = true
    end
    local used_sections = {}
    for index, service in ipairs(args.services) do
        normalized.services[index] = settings_validate_service(
            service, index - 1, state, reserved, used_sections, errors
        )
    end
    return normalized, errors
end

local function settings_ensure_section(name, section_type)
    local current_type, err = uci:get(SETTINGS_CONFIG, name)
    if current_type == nil or (current_type == false
        and (err == "Entry not found" or err == "No data")) then
        return uci:set(SETTINGS_CONFIG, name, section_type)
    end
    return current_type == section_type
end

local function settings_set_option(section, option, value)
    return value ~= nil and uci:set(SETTINGS_CONFIG, section, option, value)
end

local function settings_delete_option(section, option)
    local value, err = uci:get(SETTINGS_CONFIG, section, option)
    if value == nil or (value == false
        and (err == "Entry not found" or err == "No data")) then
        return true
    end
    if value == false then
        return false
    end
    return uci:delete(SETTINGS_CONFIG, section, option)
end

local function settings_apply_general(settings)
    if settings_has_own(settings, "assist_enable") then
        if not settings_ensure_section("assist", "basic")
            or not settings_set_option("assist", "enable", settings.assist_enable) then
            return false
        end
    end
    if settings_has_own(settings, "rpc_enable") then
        if not settings_ensure_section("rpc", "rpc")
            or not settings_set_option("rpc", "enable", settings.rpc_enable) then
            return false
        end
    end
    if settings_has_own(settings, "storage_path")
        or settings_has_own(settings, "chat_max") then
        if not settings_ensure_section("storage", "storage") then
            return false
        end
        if settings_has_own(settings, "storage_path")
            and not settings_set_option("storage", "path", settings.storage_path) then
            return false
        end
        if settings_has_own(settings, "chat_max")
            and not settings_set_option("storage", "chat_max", settings.chat_max) then
            return false
        end
    end
    if settings_has_own(settings, "rollback_enable")
        or settings_has_own(settings, "rollback_time") then
        if not settings_ensure_section("rollback", "rollback") then
            return false
        end
        if settings_has_own(settings, "rollback_enable")
            and not settings_set_option(
                "rollback", "enable", settings.rollback_enable
            ) then
            return false
        end
        if settings_has_own(settings, "rollback_time")
            and not settings_set_option("rollback", "time", settings.rollback_time) then
            return false
        end
    end
    return true
end

local function settings_apply_service(service)
    local section = service._section
    if not section then
        section = uci:add(SETTINGS_CONFIG, "service")
        if type(section) ~= "string" then
            return nil
        end
    end
    local owned = service._unsupported_provider
        and SETTINGS_COMMON_KNOWN_OPTIONS or SETTINGS_KNOWN_SERVICE_OPTIONS
    for _, option in ipairs(owned) do
        if not settings_delete_option(section, option) then
            return nil
        end
    end

    local internal = {
        _section = true,
        _api_key = true,
        _unsupported_provider = true,
        api_key_action = true
    }
    for option, value in pairs(service) do
        if not internal[option] and value ~= nil
            and not settings_set_option(section, option, value) then
            return nil
        end
    end
    if service._api_key and service._api_key ~= ""
        and not settings_set_option(section, "api_key", service._api_key) then
        return nil
    end
    return section
end

local function settings_apply_services(services, previous_sections)
    local desired = {}
    local retained = {}
    for _, service in ipairs(services) do
        local section = settings_apply_service(service)
        if not section then
            return false
        end
        desired[#desired + 1] = section
        retained[section] = true
    end
    for _, section in ipairs(previous_sections) do
        if not retained[section] and not uci:delete(SETTINGS_CONFIG, section) then
            return false
        end
    end

    local order = {}
    local iterated = uci:foreach(SETTINGS_CONFIG, nil, function(section)
        if section[".type"] ~= "service" then
            order[#order + 1] = section[".name"]
        end
    end)
    if not iterated then
        return false
    end
    for _, section in ipairs(desired) do
        order[#order + 1] = section
    end
    return uci:reorder(SETTINGS_CONFIG, order)
end

local function settings_apply_update(normalized, state)
    if not settings_apply_general(normalized.settings) then
        uci:revert(SETTINGS_CONFIG)
        return false
    end

    if not settings_apply_services(normalized.services, state.service_sections) then
        uci:revert(SETTINGS_CONFIG)
        return false
    end

    if not uci:commit(SETTINGS_CONFIG) then
        uci:revert(SETTINGS_CONFIG)
        return false
    end
    return true
end

local function settings_acquire_lock()
    -- nixio.open() accepts its create mode as an octal string (or a symbolic
    -- mode), not as a numeric POSIX mode.  Keep the lock private to root.
    local lock = nixio.open(SETTINGS_LOCK_PATH, "a", "0600")
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

local function settings_release_lock(lock)
    if not lock then
        return
    end
    lock:seek(0, "set")
    lock:lock("ulock")
    lock:close()
end

function load_settings()
    local state, revision = settings_read_stable()
    if state and revision then
        settings_write_json(settings_snapshot(state, revision))
        return
    end
    settings_write_json(
        settings_error("read_failed", "The settings configuration could not be read."),
        500, "Internal Server Error"
    )
end

local function settings_update_locked(args)
    local state, current_revision = settings_read_stable()
    if not state or not current_revision then
        return settings_error(
            "write_failed", "The settings configuration could not be read."
        ), 500, "Internal Server Error"
    end
    if args.revision ~= current_revision then
        return settings_error(
            "revision_conflict",
            "The settings changed after this page was loaded. Load the latest settings before saving again."
        ), 409, "Conflict"
    end

    local normalized, errors = settings_validate_request(args, state)
    if next(errors) ~= nil then
        return settings_error(
            "validation_failed", "One or more settings are invalid.", errors
        ), 400, "Bad Request"
    end

    -- Re-read immediately before writing.  The advisory lock serializes this
    -- API, while the second revision check also detects most changes made by
    -- other UCI clients that do not use this lock.
    local latest_state, latest_revision = settings_read_stable()
    if not latest_state or not latest_revision then
        return settings_error(
            "write_failed", "The settings configuration could not be read."
        ), 500, "Internal Server Error"
    end
    if latest_revision ~= current_revision then
        return settings_error(
            "revision_conflict",
            "The settings changed while the update was being prepared. Load the latest settings before saving again."
        ), 409, "Conflict"
    end

    if not settings_apply_update(normalized, latest_state) then
        return settings_error(
            "write_failed", "The settings could not be saved."
        ), 500, "Internal Server Error"
    end

    local updated_state, updated_revision = settings_read_stable()
    if not updated_state or not updated_revision then
        return settings_error(
            "write_failed", "The settings were saved but could not be reloaded."
        ), 500, "Internal Server Error"
    end

    local response = settings_snapshot(updated_state, updated_revision)
    response.ok = true
    return response
end

function update_settings()
    local content_length = tonumber(luci_http.getenv("CONTENT_LENGTH") or "0") or 0
    if content_length > SETTINGS_MAX_REQUEST then
        settings_write_json(
            settings_error(
                "validation_failed", "The update request is invalid.",
                { payload = "The settings payload is too large." }
            ),
            413, "Payload Too Large"
        )
        return
    end

    -- The post() target has already parsed the form to validate the CSRF
    -- token. Keep this lookup isolated so a LuCI bridge/parser failure is
    -- returned as JSON without exposing the submitted configuration or API key.
    local payload_ok, payload = pcall(luci_http.formvalue, "payload")
    if not payload_ok then
        settings_write_json(
            settings_error(
                "request_failed", "The settings request could not be read."
            ),
            500, "Internal Server Error"
        )
        return
    end
    if type(payload) ~= "string"
        or #payload == 0
        or #payload > SETTINGS_MAX_PAYLOAD then
        settings_write_json(
            settings_error(
                "validation_failed", "The update request is invalid.",
                { payload = "A valid settings payload is required." }
            ),
            400, "Bad Request"
        )
        return
    end

    local parse_ok, args = pcall(jsonc.parse, payload)
    if not parse_ok then
        settings_write_json(
            settings_error(
                "request_failed", "The settings payload could not be parsed."
            ),
            400, "Bad Request"
        )
        return
    end
    if type(args) ~= "table"
        or type(args.revision) ~= "string"
        or args.revision == ""
        or #args.revision > 128
        or settings_has_control(args.revision) then
        settings_write_json(
            settings_error(
                "validation_failed", "The update request is invalid.",
                { revision = "A settings revision is required." }
            ),
            400, "Bad Request"
        )
        return
    end

    local lock_ok, lock = pcall(settings_acquire_lock)
    if not lock_ok then
        settings_write_json(
            settings_error(
                "write_failed", "The settings update lock could not be acquired."
            ),
            500, "Internal Server Error"
        )
        return
    end
    if not lock then
        settings_write_json(
            settings_error(
                "write_failed", "The settings update lock could not be acquired."
            ),
            503, "Service Unavailable"
        )
        return
    end

    local ok, body, status, status_message = pcall(
        settings_update_locked, args
    )
    if not ok then
        pcall(function()
            uci:revert(SETTINGS_CONFIG)
        end)
        body = settings_error(
            "write_failed", "An unexpected error prevented the settings update."
        )
        status = 500
        status_message = "Internal Server Error"
    end
    settings_release_lock(lock)
    settings_write_json(body, status, status_message)
end
