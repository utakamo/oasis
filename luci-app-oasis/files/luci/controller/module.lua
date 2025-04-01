local sys = require("luci.sys")
local util = require("luci.util")
local uci = require("luci.model.uci").cursor()
local luci_http = require("luci.http")
local jsonc = require("luci.jsonc")
local oasis = require("oasis.chat.apply")
local common = require("oasis.common")
local transfer = require("oasis.chat.transfer")
local nixio = require("nixio")

module("luci.controller.luci-app-oasis.module", package.seeall)

function index()
    entry({"admin", "network", "oasis"}, firstchild(), "Oasis", 30).dependent=false
    entry({"admin", "network", "oasis", "icons"}, template("luci-app-oasis/icons"), "Icon", 40).dependent=false
    entry({"admin", "network", "oasis", "sysmsg"}, template("luci-app-oasis/sysmsg"), "System Message", 30).dependent=false
    entry({"admin", "network", "oasis", "setting"}, cbi("luci-app-oasis/setting"), "General Setting", 20).dependent=false
    entry({"admin", "network", "oasis", "chat"}, template("luci-app-oasis/chat"), "Chat with AI", 10).dependent=false
    entry({"admin", "network", "oasis", "chat-list"}, call("retrive_chat_list"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-chat-data"}, call("load_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "export-chat-data"}, call("load_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "import-chat-data"}, call("import_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "delete-chat-data"}, call("delete_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "rename-chat"}, call("rename"), nil).leaf = true
    entry({"admin", "network", "oasis", "apply-uci-cmd"}, call("apply_uci_cmd"), nil).leaf = true
    entry({"admin", "network", "oasis", "confirm"}, call("confirm"), nil).leaf = true
    entry({"admin", "network", "oasis", "finalize"}, call("finalize"), nil).leaf = true
    entry({"admin", "network", "oasis", "rollback"}, call("rollback"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-sysmsg"}, call("load_sysmsg"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-sysmsg-info"}, call("load_sysmsg_info"), nil).leaf = true
    entry({"admin", "network", "oasis", "update-sysmsg"}, call("update_sysmsg"), nil).leaf = true
    entry({"admin", "network", "oasis", "add-sysmsg"}, call("add_sysmsg"), nil).leaf = true
    entry({"admin", "network", "oasis", "delete-sysmsg"}, call("delete_sysmsg"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-icon-info"}, call("load_icon_info"), nil).leaf = true
    entry({"admin", "network", "oasis", "select-icon"}, call("select_icon"), nil).leaf = true
    entry({"admin", "network", "oasis", "upload-icon-data"}, call("upload_icon_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "delete-icon-data"}, call("delete_icon_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "uci-config-list"}, call("uci_config_list"), nil).leaf = true
    entry({"admin", "network", "oasis", "uci-show"}, call("uci_show"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-extra-sysmsg"}, call("load_extra_sysmsg"), nil).leaf = true
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

function retrive_chat_list()

    -- os.execute("echo retrive_chat_list called >> /tmp/oasis-retrieve.log")

    -- ubus call
    local result = util.ubus("oasis.chat", "list", {})

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function load_chat_data()

    -- os.execute("echo load_chat_data called >> /tmp/oasis-load.log")

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

    local conf = common.get_oasis_conf()
    local file_name = conf.prefix .. id
    local full_file_path = common.normalize_path(conf.path) .. file_name
    common.touch(full_file_path)

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

    local unnamed_section = uci:add("oasis", "chat")

    uci:set("oasis", unnamed_section, "id", result.id)
    uci:set("oasis", unnamed_section, "title", result.title)
    uci:commit("oasis")

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function delete_chat_data()

    -- os.execute("echo delete_chat_data called >> /tmp/oasis-delete.log")

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

    -- os.execute("echo rename called >> /tmp/oasis-rename.log")

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

    -- os.execute("echo apply_uci_cmd called >> /tmp/oasis-apply.log")

    local uci_list_json = luci_http.formvalue("uci_list")
    local chat_id = luci_http.formvalue("id")
    local apply_type = luci_http.formvalue("type")

    if (not uci_list_json) or (not chat_id) then
        -- for debug
        -- os.execute("echo \"apply_uci_cmd argument error\" >> /tmp/oasis-apply.log")
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    -- for debug
    -- os.execute("echo \"chat_id = " .. chat_id .. "\" >> /tmp/oasis-apply.log")
    -- os.execute("echo \"uci_list_json" .. uci_list_json .. "\" >> /tmp/oasis-apply.log")

    local uci_list = jsonc.parse(uci_list_json)

    -- initialize flag file for oasis_rollback
    os.remove("/tmp/oasis/apply/complete")
    os.remove("/tmp/oasis/apply/rollback")

    if apply_type == "commit" then
        oasis.backup(uci_list, chat_id, "normal")
        oasis.apply(uci_list, true) -- true: commit uci config (/etc/config/~)
    else
        oasis.apply(uci_list, false) -- false: save uci config (/tmp/.uci/~)
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json("OK")
end

function confirm()
    -- os.execute("echo \"finalize_settings error\" >> /tmp/oasis-confirm.log")
    local result = util.ubus("oasis", "confirm")
    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function finalize()

    local result = sys.exec("touch /tmp/oasis/apply/complete;echo $?")

    luci_http.prepare_content("application/json")

    if result == 0 then
        luci_http.write_json("ERROR")
    else
        luci_http.write_json("OK")
    end
end

function rollback()
    local result = sys.exec("touch /tmp/oasis/apply/rollback;echo $?")

    luci_http.prepare_content("application/json")

    if result == 0 then
        luci_http.write_json("ERROR")
    else
        luci_http.write_json("OK")
    end
end

function load_sysmsg()

    local json_param = {
        path = "/etc/oasis/oasis.conf"
    }

    local result = util.ubus("oasis", "load_sysmsg", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function load_sysmsg_info()

    local json_param = {
        path = "/etc/oasis/oasis.conf"
    }

    local result = util.ubus("oasis", "load_sysmsg_info", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function update_sysmsg()

    -- os.execute("echo rename called >> /tmp/oasis-rename.log")

    local target = luci_http.formvalue("target")
    local title = luci_http.formvalue("title")
    local message = luci_http.formvalue("message")

    if (not target) or (not title) or (not message) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local json_param = {path = "/etc/oasis/oasis.conf", target = target, title = title, message = message}

    local result = util.ubus("oasis", "update_sysmsg", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function add_sysmsg()

    local title = luci_http.formvalue("title")
    local message = luci_http.formvalue("message")

    if (not title) or (not message) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local json_param = {path = "/etc/oasis/oasis.conf", title = title, message = message}

    local result = util.ubus("oasis", "add_sysmsg", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function delete_sysmsg()

    local target = luci_http.formvalue("target")

    if not target then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local json_param = {path = "/etc/oasis/oasis.conf", target = target}

    local result = util.ubus("oasis", "delete_sysmsg", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function load_icon_info()
    local json_param = {path = "/etc/oasis/oasis.conf"}

    local result = util.ubus("oasis", "load_icon_info", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function select_icon()

    local using = luci_http.formvalue("using")

    if not using then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    local json_param = {path = "/etc/oasis/oasis.conf", using = using}

    local result = util.ubus("oasis", "select_icon", json_param)

    luci_http.prepare_content("application/json")
    luci_http.write_json(result)
end

function upload_icon_data()

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

function uci_config_list()

    -- Currently, the only removal target in the uci config list is oasis and rpcd.
    -- Add the names of uci configs that you don't want to teach AI here.
    local black_list = {
        "oasis",
        "rpcd",
    }

    local list = util.ubus("uci", "configs", {})

    if (not list) or (not list.configs) then
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "No uci list" })
        return
    end

    for index = #list.configs, 1, -1 do
        for _, exclude_item in ipairs(black_list) do
            if list.configs[index] == exclude_item then
                table.remove(list.configs, index)
                break
            end
        end
    end

    luci_http.prepare_content("application/json")
    luci_http.write_json(list)
end

function uci_show()
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
