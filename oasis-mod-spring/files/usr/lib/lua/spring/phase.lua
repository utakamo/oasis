local matrix    = require("spring.matrix.master")
local util      = require("luci.util")
local uci       = require("luci.model.uci").cursor()

-- How to activate debug: uci set oasis.chat.debug=1
local debug     = require("oasis.chat.debug")

local register_phase_base_tbl = function(utype)

    local phase_base_tbl = {}

    uci:foreach("spring", utype, function(tbl)

        phase_base_tbl[#phase_base_tbl + 1] = {}

        if tbl.type then
            phase_base_tbl[#phase_base_tbl].type = tbl.type
        end

        if tbl.name then
            phase_base_tbl[#phase_base_tbl].name = tbl.name
        end

        if tbl.args then
            phase_base_tbl[#phase_base_tbl].args = {}
            for idx, value in ipairs(tbl.args) do
                phase_base_tbl[#phase_base_tbl].args[idx] = value
            end
        end

        if tbl.judge then
            phase_base_tbl[#phase_base_tbl].judge = {}
            for idx, value in ipairs(tbl.judge) do
                phase_base_tbl[#phase_base_tbl].judge[idx] = value
            end
        end

        if tbl.next_phase then
            phase_base_tbl[#phase_base_tbl].next_phase = tbl.next_phase
        end
    end)

    return phase_base_tbl
end

-- function_defines is master list
local defines = {}
matrix.register_luacode_event_detecter_func(defines, false, "get_wired_if_list", function()

    local result = util.ubus("network.interface", "dump", {})

    local interfaces = {}

    if result and result.interface then
        for _, iface in ipairs(result.interface) do
            if iface.interface then
                table.insert(interfaces, iface.interface)
            end
        end
    end

    -- debug:log("spring.log", "get_wired_if_list called")
    -- debug:dump("spring.log", interfaces)

    return interfaces
end)

matrix.register_luacode_event_detecter_func(defines, false, "get_wireless_if_list", function()

    local result = util.ubus("iwinfo", "devices", {})

    if not result or not result.devices then
        return nil
    end

    local interfaces = result.devices

    return interfaces
end)

matrix.register_luacode_event_detecter_func(defines, false, "output", function()
    return "Hello Practice"
end)

matrix.register_luacode_event_detecter_func(defines, false, "get_os_name", function()
    local handle = io.popen("uname -o")
    local result = handle:read("*a")
    handle:close()
    return result:match("^%s*(.-)%s*$")
end)

matrix.register_luacode_event_detecter_func(defines, false, "get_kernel_version", function()
    local handle = io.popen("uname -r")
    local result = handle:read("*a")
    handle:close()
    return result:match("^%s*(.-)%s*$")
end)

matrix.register_luacode_event_detecter_func(defines, false, "get_used_memory", function()
    local info = util.ubus("system", "info", {})

    if not info or not info.memory then
        return nil
    end

    local mem = info.memory
    local used = mem.total - mem.free - (mem.buffered or 0) - (mem.cached or 0)

    return used
end)

matrix.register_luacode_event_detecter_func(defines, false, "get_load_average", function()
    local handle = io.popen("cat /proc/loadavg")
    local line = handle:read("*l")
    handle:close()
    local load1, load5, load15 = line:match("([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
    return {
        ["1min"] = load1,
        ["5min"] = load5,
        ["15min"] = load15
    }
end)

matrix.register_luacode_event_detecter_func(defines, true, "get_ip_address", function(args)
    debug:log("oasis.log", "get_ip_address", "called!!")
    local interface = args[1] or "eth0"  -- Default to eth0 if no argument is provided
    local cmd = string.format("ip -4 addr show %s | grep inet", interface)
    local handle = io.popen(cmd)
    local line = handle:read("*l")
    handle:close()
    return line and line:match("inet ([%d%.]+)") or nil
end)

matrix.register_ccode_event_detecter_func(defines, true, "get_ifname_from_idx")
matrix.register_ccode_event_detecter_func(defines, true, "get_if_ipv4")
matrix.register_ccode_event_detecter_func(defines, true, "get_netmask")
matrix.register_ccode_event_detecter_func(defines, true, "get_mtu")
matrix.register_ccode_event_detecter_func(defines, true, "get_mac_addr")
-- Type Code Only
-------------------------------------------------------
--                   [PHASE 1]                       --
-------------------------------------------------------

local evt_base_tbl = {}
local act_base_tbl = {}

local phase_event_type_list = {
    "phase_a_event",
    "phase_b_event",
}

local phase_action_type_list = {
    "phase_a_action",
    "phase_b_action",
}

for _, uci_phase_type in ipairs(phase_event_type_list) do
    evt_base_tbl[#evt_base_tbl + 1] = register_phase_base_tbl(uci_phase_type)
end

for _, uci_phase_type in ipairs(phase_action_type_list) do
    act_base_tbl[#act_base_tbl + 1] = register_phase_base_tbl(uci_phase_type)
end

debug:log("oasis.log", "init", "Event")
debug:dump("oasis.log", evt_base_tbl)

debug:log("oasis.log", "init", "Action")
debug:dump("oasis.log", act_base_tbl)

-- #1 func config
-- uci add spring
--[[
local phase1_evt_base_tbl = {}
phase1_evt_base_tbl[#phase1_evt_base_tbl + 1]     = {}
phase1_evt_base_tbl[#phase1_evt_base_tbl].args    = {}
phase1_evt_base_tbl[#phase1_evt_base_tbl].type    = "luacode"
phase1_evt_base_tbl[#phase1_evt_base_tbl].name    = "get_ifame"
phase1_evt_base_tbl[#phase1_evt_base_tbl].args[1] = "Hello "
phase1_evt_base_tbl[#phase1_evt_base_tbl].args[2] = "World\n"

-- #2 func config
phase1_evt_base_tbl[#phase1_evt_base_tbl + 1]     = {}
phase1_evt_base_tbl[#phase1_evt_base_tbl].args    = {}
phase1_evt_base_tbl[#phase1_evt_base_tbl].type    = "luacode"
phase1_evt_base_tbl[#phase1_evt_base_tbl].name    = "get_wireless_if_list"

-- #3 func config
phase1_evt_base_tbl[#phase1_evt_base_tbl + 1]     = {}
phase1_evt_base_tbl[#phase1_evt_base_tbl].args    = {}
phase1_evt_base_tbl[#phase1_evt_base_tbl].type    = "luacode"
phase1_evt_base_tbl[#phase1_evt_base_tbl].name    = "output"

-- Type Script Only
phase1_evt_base_tbl[#phase1_evt_base_tbl + 1]  = {}
phase1_evt_base_tbl[#phase1_evt_base_tbl].type = "luascript"
phase1_evt_base_tbl[#phase1_evt_base_tbl].name = "testscript"
]]
-------------------------------------------------------
--                   [PHASE 2]                       --
-------------------------------------------------------
--[[
local phase2_evt_base_tbl          = {}
phase2_evt_base_tbl[#phase2_evt_base_tbl + 1]      = {}
phase2_evt_base_tbl[#phase2_evt_base_tbl].args     = {}
phase2_evt_base_tbl[#phase2_evt_base_tbl].type     = "luacode"
phase2_evt_base_tbl[#phase2_evt_base_tbl].name     = "get_wired_if_list"

phase2_evt_base_tbl[#phase2_evt_base_tbl + 1]      = {}
phase2_evt_base_tbl[#phase2_evt_base_tbl].args     = {}
phase2_evt_base_tbl[#phase2_evt_base_tbl].type     = "luacode"
phase2_evt_base_tbl[#phase2_evt_base_tbl].name     = "get_ip_address"
phase2_evt_base_tbl[#phase2_evt_base_tbl].args[1]  = "eth0"

phase2_evt_base_tbl[#phase2_evt_base_tbl + 1]      = {}
phase2_evt_base_tbl[#phase2_evt_base_tbl].args     = {}
phase2_evt_base_tbl[#phase2_evt_base_tbl].type     = "luacode"
phase2_evt_base_tbl[#phase2_evt_base_tbl].name     = "get_kernel_version"

phase2_evt_base_tbl[#phase2_evt_base_tbl + 1]      = {}
phase2_evt_base_tbl[#phase2_evt_base_tbl].args     = {}
phase2_evt_base_tbl[#phase2_evt_base_tbl].type     = "luacode"
phase2_evt_base_tbl[#phase2_evt_base_tbl].name     = "get_os_name"
]]

local matrix_phase_tbl = {}
matrix_phase_tbl[#matrix_phase_tbl + 1] = matrix.create_phase(defines, evt_base_tbl[1], act_base_tbl[1]) -- phase1
matrix_phase_tbl[#matrix_phase_tbl + 1] = matrix.create_phase(defines, evt_base_tbl[2], act_base_tbl[2], 1) -- phase2

function test_exec_allevents()
    debug:log("oasis.log", "test_exec_allevents", "called by springd")
    for idx, phase in ipairs(matrix_phase_tbl) do
        print("---- " .. "[PHASE " .. idx .. "] ----")
        matrix.execute_phase(phase)
    end
end

function get_phase_max_idx()
    return #matrix_phase_tbl
end

function execute_target_phase(idx)
    local next_phase = matrix.execute_phase(matrix_phase_tbl[idx])
    return next_phase
end
