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
local client        = require("oasis.local.tool.client")
local debug         = require("oasis.chat.debug")

module("luci.controller.luci-app-oasis.module", package.seeall)

local local_tools = uci:get_bool(common.db.uci.config, common.db.uci.sect.support, "local_tools")
local remote_mcp_server = uci:get_bool(common.db.uci.config, common.db.uci.sect.support, "remote_mcp_server")
local spring = uci:get_bool(common.db.uci.config, common.db.uci.sect.support, "spring")

function index()
    entry({"admin", "network", "oasis"}, firstchild(), "Oasis", 30).dependent=false
    entry({"admin", "network", "oasis", "icons"}, template("luci-app-oasis/icons"), "Icon", 60).dependent=false
    entry({"admin", "network", "oasis", "rollback-list"}, template("luci-app-oasis/rollback-list"), "Rollback List", 50).dependent=false
    -- if local_tools or remote_mcp_server then
    --     entry({"admin", "network", "oasis", "rollback-list"}, template("luci-app-oasis/tools-mcp"), "Tools/Remote MCP", 40).dependent=false
    -- end
    entry({"admin", "network", "oasis", "sysmsg"}, template("luci-app-oasis/sysmsg"), "System Message", 30).dependent=false
    entry({"admin", "network", "oasis", "setting"}, cbi("luci-app-oasis/setting"), "General Setting", 20).dependent=false
    entry({"admin", "network", "oasis", "chat"}, template("luci-app-oasis/chat"), "Chat with AI", 10).dependent=false
    entry({"admin", "network", "oasis", "load-chat-data"}, call("load_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "export-chat-data"}, call("load_chat_data"), nil).leaf = true
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
    entry({"admin", "network", "oasis", "load-rollback-list"}, call("load_rollback_list"), nil).leaf = true
    entry({"admin", "network", "oasis", "rollback-target-data"}, call("rollback_target_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "base-info"}, call("base_info"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-local-tools-info"}, call("load_local_tools_info"), nil).leaf = true
    entry({"admin", "network", "oasis", "change-tool-enable"}, call("change_tool_enable"), nil).leaf = true
    entry({"admin", "network", "oasis", "add-remote-mcp-server"}, call("add_remote_mcp_server"), nil).leaf = true
    entry({"admin", "network", "oasis", "remove-remote-mcp-server"}, call("remove_remote_mcp_server"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-local-tools-info"}, call("load_local_tools_info"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-server-info"}, call("load_server_info"), nil).leaf = true
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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][load_chat_data] ---")

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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][import_chat_data] ---")
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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][delete_chat_data] ---")

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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][rename] ---")

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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][apply_uci_cmd] ---")

    local uci_list_json = luci_http.formvalue("uci_list")
    local chat_id = luci_http.formvalue("id")
    local apply_type = luci_http.formvalue("type")

    if (not uci_list_json) or (not chat_id) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    -- debug:log("luci-app-oasis.log", "chat id = " .. chat_id)
    -- debug:log("luci-app-oasis.log", "uci_list_json = " .. uci_list_json)

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
    luci_http.write_json("OK")
end

function confirm()
    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][confirm] ---")
    local result = util.ubus("oasis", "confirm")
    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function finalize()

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][finalize] ---")
    local result = sys.exec("touch /tmp/oasis/apply/complete;echo $?")

    luci_http.prepare_content("application/json")

    if result == 0 then
        luci_http.write_json("ERROR")
    else
        luci_http.write_json("OK")
    end
end

function rollback()
    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][rollback] ---")
    local result = sys.exec("touch /tmp/oasis/apply/rollback;echo $?")

    luci_http.prepare_content("application/json")

    if result == 0 then
        luci_http.write_json("ERROR")
    else
        luci_http.write_json("OK")
    end
end

function load_sysmsg_data()

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][load_sysmsg_data] ---")

    local result = util.ubus("oasis", "load_sysmsg_data", {})

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function update_sysmsg_data()

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][update_sysmsg_data] ---")

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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][add_sysmsg_data] ---")

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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][delete_sysmsg_data] ---")

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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][load_icon_info] ---")

    local result = util.ubus("oasis", "load_icon_info", {})

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function select_icon()

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][select_icon] ---")
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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][upload_icon_data] ---")
    local filename = luci_http.formvalue("filename")
    local image = luci_http.formvalue("image")

    if (not filename) or (not image) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local data = common.load_conf_file("/etc/oasis/oasis.conf")

    local icon_key_suffix
    for icon_key, name in pairs(data.icons) do
        icon_key_suffix = icon_key:match("icon_(%d+)")

        if icon_key_suffix then
            if name == filename then
                luci_http.prepare_content("application/json")
                luci_http.write_json({ error = "An image file with the same name already exists" })
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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][delete_icon_data] ---")
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

    if not common.update_conf_file("/etc/oasis/oasis.conf", data) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Failed to delete icon info" })
        return
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json("OK")
end

function uci_show()

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][uci_show] ---")
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

    -- debug:log("luci-app-oasis.log", "\n--- [module.lua][load_extra_sysmsg] ---")
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

function load_rollback_list()

    -- debug:log("oasis.log", "\n--- [modlue.lua][load_rollback_list] ---")
    local rollback_list = oasis.get_rollback_data_list()

    if not rollback_list then
        -- debug:log("oasis.log", "Failed to load config")
        luci_http.prepare_content("application/json")
        luci_http.write_json({error = "Failed to load config"})
        return
    end

    -- debug:log("oasis.log", "Failed to load config")
    luci_http.prepare_content("application/json")
    luci_http.write_json(rollback_list)
end

function rollback_target_data()

    debug:log("oasis.log", "\n--- [module.lua][rollback_target_data] ---")
    local index = luci_http.formvalue("index")

    if not index then
        debug:log("oasis.log", "Missing params")
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local result = oasis.rollback_target_data(index)

    if not result then
        debug:log("oasis.log", "Failed to rollback data")
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Failed to rollback data" })
        return
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json({ status = "OK" })
    os.execute("reboot")
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

function load_local_tools_info()
    local tools = {}
    uci:foreach("oasis", "tool", function(s)
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
        table.insert(tools, entry)
    end)
    luci_http.prepare_content("application/json")
    luci_http.write_json(tools)
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

function load_server_info()

    local list = {}

    uci:foreach(common.db.uci.config, common.db.uci.sect.tool, function(s)

        if not list[s.server] then
            list[s.server] = {}
            list[s.server].status = "loading"
        end

        if not list[s.server].funcs then
            list[s.server].funcs = {}      
        end

        list[s.server].funcs[#list[s.server].funcs + 1] = {}
        list[s.server].funcs[#list[s.server].funcs].name = s.name
        list[s.server].funcs[#list[s.server].funcs].enable = s.enable
    end)

    for server, _ in pairs(list) do
        if client.check_server_loaded(server) then
            list[server].status = "loaded"
        end
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json(list)
end