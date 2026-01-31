local uci = require("luci.model.uci").cursor()
local luci_http = require("luci.http")
local common = require("oasis.common")
local jsonc = require("luci.jsonc")
local tmpl = require("oasis.tool.maker.template")

module("luci.controller.oasis-tool-maker.module", package.seeall)

local function write_json(payload)
    luci_http.prepare_content("application/json")
    luci_http.write_json(payload)
end

function index()
    local is_webui_support = uci:get_bool(common.db.uci.cfg, common.db.uci.sect.support, "webui")
    if not is_webui_support then
        return
    end

    entry({"admin", "network", "oasis", "tool-maker"}, template("oasis/tool-maker"), "Tool Maker", 60).dependent = false
    entry({"admin", "network", "oasis", "tool-maker-render"}, call("tool_maker_render"), nil).leaf = true
    entry({"admin", "network", "oasis", "tool-maker-save"}, call("tool_maker_save"), nil).leaf = true
    entry({"admin", "network", "oasis", "tool-maker-validate"}, call("tool_maker_validate"), nil).leaf = true
end

function tool_maker_render()
    local tool_type = luci_http.formvalue("type") or "lua"
    local name = luci_http.formvalue("name") or ""
    local tools_json = luci_http.formvalue("tools") or "[]"
    local tools = jsonc.parse(tools_json)
    if type(tools) ~= "table" then
        write_json({ status = "NG", error = "invalid tools" })
        return
    end

    local content, err = tmpl.render(tool_type, tools, name)
    if not content then
        write_json({ status = "NG", error = err or "failed to render" })
        return
    end

    write_json({ status = "OK", content = content })
end

function tool_maker_validate()
    local tool_type = luci_http.formvalue("type") or "lua"
    local name = luci_http.formvalue("name") or ""
    local tools_json = luci_http.formvalue("tools") or "[]"
    local tools = jsonc.parse(tools_json)
    if type(tools) ~= "table" then
        write_json({ status = "NG", errors = { "invalid tools" } })
        return
    end

    local ok, errors = tmpl.validate(tool_type, tools, name)
    if not ok then
        write_json({ status = "NG", errors = errors })
        return
    end

    write_json({ status = "OK", errors = {} })
end

function tool_maker_save()
    local tool_type = luci_http.formvalue("type") or "lua"
    local name = luci_http.formvalue("name") or ""
    local tools_json = luci_http.formvalue("tools") or "[]"
    local tools = jsonc.parse(tools_json)
    if type(tools) ~= "table" then
        write_json({ status = "NG", error = "invalid tools" })
        return
    end

    local valid, errors = tmpl.validate(tool_type, tools, name)
    if not valid then
        write_json({ status = "NG", error = errors and errors[1] or "invalid body" })
        return
    end

    local content, render_err = tmpl.render(tool_type, tools, name)
    if not content then
        write_json({ status = "NG", error = render_err or "failed to render" })
        return
    end

    local ok, info_or_err = tmpl.save(tool_type, name, content)
    if not ok then
        write_json({ status = "NG", error = info_or_err })
        return
    end

    write_json({ status = "OK", path = info_or_err.path, bytes = info_or_err.bytes })
end
