local luci_http     = require("luci.http")
local oasis         = require("oasis.chat.apply")
local debug         = require("oasis.chat.debug")

module("luci.controller.oasis-retired.module", package.seeall)

function index()
    entry({"admin", "network", "oasis", "rollback-list"}, template("oasis/rollback-list"), "Rollback List", 40).dependent=false
    entry({"admin", "network", "oasis", "load-rollback-list"}, call("load_rollback_list"), nil).leaf = true
    entry({"admin", "network", "oasis", "rollback-target-data"}, call("rollback_target_data"), nil).leaf = true
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
