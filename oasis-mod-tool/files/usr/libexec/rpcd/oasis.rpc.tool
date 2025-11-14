#!/usr/bin/env lua

local server = require("oasis.local.tool.server")

server.tool("get_tool_info", {
    tool_desc = "Get tool list",
    call = function()
        local uci = require("luci.model.uci").cursor()
        local jsonc = require("luci.jsonc")
        local tool = {}

        local info = uci:get_all("oasis")

        for _, target in pairs(info) do
            if (target[".type"] == "tool")  then
                tool[#tool + 1] = {
                    server = target.server,
                    name   = target.name,
                    enable = target.enable
                }
            end
        end

        local r = {}
        r.result = jsonc.stringify({ tool = tool })
        return r
    end
})

server.tool("set_tool_enabled", {
    tool_desc = "Enable the tool",
    args_desc = { "Tool Name" },
    args = { tool = "a_string" },
    call = function(args)
        local uci = require("luci.model.uci").cursor()
        local jsonc = require("luci.jsonc")

        local info = uci:get_all("oasis")
        local is_changed = false

        for sect, _ in pairs(info) do
            local target = info[sect]
            if (target[".type"] == "tool") and (target.name == args.tool) then
                uci:set("oasis", sect, "enable", 1)
                uci:commit("oasis")
                is_changed = true
                break
            end
        end

        local r = {}
        r.result = jsonc.stringify({status = "NG", comment = "Failed to enable the tool."})

        if is_changed then
            r.result = jsonc.stringify({status = "OK", comment = "The tool has been enabled."})
        end

        return r
    end
})

server.tool("set_tool_disabled", {
    tool_desc = "Disable the tool",
    args_desc = { "Tool Name" },
    args = { tool = "a_string" },
    call = function(args)
        local uci = require("luci.model.uci").cursor()
        local jsonc = require("luci.jsonc")

        local info = uci:get_all("oasis")
        local is_changed = false

        for sect, _ in pairs(info) do
            local target = info[sect]
            if (target[".type"] == "tool") and (target.name == args.tool) then
                uci:set("oasis", sect, "enable", 0)
                uci:commit("oasis")
                is_changed = true
                break
            end
        end

        local r = {}
        r.result = jsonc.stringify({status = "NG", comment = "Failed to disable the tool."})

        if is_changed then
            r.result = jsonc.stringify({status = "OK", comment = "The tool has been disabled."})
        end

        return r
    end
})

server.run(arg)