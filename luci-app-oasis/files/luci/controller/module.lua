local sys = require("luci.sys")
local util = require("luci.util")
local luci_http = require("luci.http")
local jsonc = require("luci.jsonc")
local oasis = require("oasis.chat.apply")

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
    entry({"admin", "network", "oasis", "delete-chat-data"}, call("delete_chat_data"), nil).leaf = true
    entry({"admin", "network", "oasis", "rename-chat"}, call("rename"), nil).leaf = true
    entry({"admin", "network", "oasis", "apply-uci-cmd"}, call("apply_uci_cmd"), nil).leaf = true
    entry({"admin", "network", "oasis", "confirm"}, call("confirm"), nil).leaf = true
    entry({"admin", "network", "oasis", "finalize"}, call("finalize"), nil).leaf = true
    entry({"admin", "network", "oasis", "rollback"}, call("rollback"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-sysmsg"}, call("load_sysmsg"), nil).leaf = true
    entry({"admin", "network", "oasis", "update-sysmsg"}, call("update_sysmsg"), nil).leaf = true
    entry({"admin", "network", "oasis", "add-sysmsg"}, call("add_sysmsg"), nil).leaf = true
    entry({"admin", "network", "oasis", "delete-sysmsg"}, call("delete_sysmsg"), nil).leaf = true
    entry({"admin", "network", "oasis", "load-icon-info"}, call("load_icon_info"), nil).leaf = true
    entry({"admin", "network", "oasis", "select-icon"}, call("select_icon"), nil).leaf = true
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
        os.execute("echo \"apply_uci_cmd argument error\" >> /tmp/oasis-apply.log")
        luci_http.prepare_content("application/json")
        luci_http.write_json({ error = "Missing params" })
        return
    end

    -- for debug
    os.execute("echo \"chat_id = " .. chat_id .. "\" >> /tmp/oasis-apply.log")
    os.execute("echo \"uci_list_json" .. uci_list_json .. "\" >> /tmp/oasis-apply.log")

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
    os.execute("echo \"finalize_settings error\" >> /tmp/oasis-confirm.log")
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