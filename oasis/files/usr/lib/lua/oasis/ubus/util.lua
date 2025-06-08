#!/usr/bin/env lua

local jsonc = require("luci.jsonc")
local uci = require("luci.model.uci").cursor()
local common = require("oasis.common")

------------------------------
-- [Used from oasis object] --
------------------------------
local retrieve_config = function()
    local storage_tbl = uci:get_all(common.db.uci.cfg, common.db.uci.sect.storage)
    local storage_json = jsonc.stringify(storage_tbl)
    return storage_json
end

return {
    retrieve_config = retrieve_config,
}