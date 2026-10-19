local jsonc = require("luci.jsonc")
local M = {}

local function replace(t, name, value)
    local old = package.loaded[name]
    package.loaded[name] = value
    t:on_cleanup(function() package.loaded[name] = old end)
end

local function fixture(t)
    local env = { applied = 0, prepared = 0, interactive = true, enabled = true, output = {}, inputs = { "value", "y" } }
    env.tool = { name = "fixture_edit", server = "fixture.server", enabled = true, enable = "1" }
    env.action = { version = 1, type = "fixture", operation = "edit",
        fields = { { name = "value", label = "Value", type = "string", required = true } } }
    env.handler = {
        prepare = function(action)
            env.prepared = env.prepared + 1
            return {}, { form = { title = "Fixture form", fields = action.fields } }
        end,
        advance = function(state, values) state.values = values; return { ready = true } end,
        apply = function(state) env.applied = env.applied + 1; env.values = state.values; return { ok = true } end,
    }
    replace(t, "oasis.test.fixture_ui_handler", env.handler)
    replace(t, "oasis.ui.registry", nil)
    local registry = require("oasis.ui.registry")
    local old_load = registry.load
    t:on_cleanup(function() registry.load = old_load end)
    env.entries = { fixture = { version = 1, type = "fixture", handler = "oasis.test.fixture_ui_handler", allow_fields = true,
        bindings = { { server = "fixture.server", method = "fixture_edit", operation = "edit" } } } }
    registry.load = function() return env.entries end
    replace(t, "luci.model.uci", { cursor = function() return {} end })
    replace(t, "oasis.local.tool.state", { snapshot = function(_, token)
        if env.mode_changed then return nil end
        local tool = {}
        for k, v in pairs(env.tool) do tool[k] = v end
        tool.enabled = env.enabled
        return { token = token, tools = { tool } }
    end })
    replace(t, "oasis.ui.runner", nil)
    env.runner = require("oasis.ui.runner")
    local index = 0
    local function read()
        index = index + 1
        if env.on_read then env.on_read(index) end
        return env.inputs[index]
    end
    env.terminal = { is_interactive = function() return env.interactive end,
        print = function(text) env.output[#env.output + 1] = text or "" end,
        write = function(text) env.output[#env.output + 1] = text end,
        flush = function() end, read_form_line = read, read_secret = read }
    function env.capture(action)
        local output = { ui_action = action or env.action, status = "input_required" }
        env.runner.capture(env.tool, "fixture_edit", output, "0:0", {})
        return { tool_call_id = "call-1", name = env.tool.name, output = jsonc.stringify(output, false) }
    end
    function env.finish(outputs, ok)
        return env.runner.finish({ ok = ok ~= false, tool_info = jsonc.stringify({ tool_outputs = outputs }, false) }, env.terminal)
    end
    env.runner.begin()
    return env
end

function M.register(harness)
    harness:test("unit", "UI actions use registered non-Wi-Fi handlers and deduplicate tool call IDs", function(t)
        local env = fixture(t)
        local output = env.capture()
        t:assert_equal(0, env.prepared, "input began before the AI turn ended")
        t:assert_equal(0, env.finish({ output, output }))
        t:assert_equal(1, env.applied)
        t:assert_equal("value", env.values.value)
        t:assert_equal(0, env.finish({ output }), "a completed request was replayed")
        t:assert_equal(1, env.applied)
    end)

    harness:test("unit", "UI actions discard failed turns and never prompt without a TTY", function(t)
        for _, mode in ipairs({ "failed", "non_tty" }) do
            local env = fixture(t)
            local output = env.capture()
            env.interactive = mode ~= "non_tty"
            t:assert_equal(mode == "non_tty" and 2 or 0, env.finish({ output }, mode ~= "failed"))
            t:assert_equal(0, env.prepared)
            t:assert_equal(0, env.applied)
        end
    end)

    harness:test("unit", "UI actions require consent and recheck permission after input", function(t)
        for _, mode in ipairs({ "cancel", "eof", "permission", "generation" }) do
            local env = fixture(t)
            local output = env.capture()
            if mode == "cancel" then env.inputs = { "/cancel" }
            elseif mode == "eof" then env.inputs = {}
            else env.on_read = function()
                if mode == "permission" then env.enabled = false else env.mode_changed = true end
            end end
            t:assert_equal(1, env.finish({ output }))
            t:assert_equal(0, env.applied)
        end
    end)

    harness:test("unit", "UI actions reject unknown handlers, versions and forged operation bindings", function(t)
        for _, mode in ipairs({ "type", "version", "operation", "result" }) do
            local env = fixture(t)
            if mode == "result" then
                local output = env.capture()
                output.output = jsonc.stringify({ ui_action = env.action, forged = true }, false)
                t:assert_equal(1, env.finish({ output }))
            else
                env.action[mode] = mode == "version" and 2 or "unknown"
                t:assert_equal(1, env.finish({ env.capture() }))
            end
            t:assert_equal(0, env.applied)
        end
    end)

    harness:test("unit", "UI action handler exceptions cannot print entered secrets", function(t)
        local env = fixture(t)
        env.handler.advance = function() error("PRIVATE_INPUT_SENTINEL") end
        t:assert_equal(1, env.finish({ env.capture() }))
        t:assert_not_contains(table.concat(env.output), "PRIVATE_INPUT_SENTINEL")
        t:assert_equal(0, env.applied)
    end)

    harness:test("unit", "UI registrations require trusted files and reject duplicate IDs", function(t)
        for _, mode in ipairs({ "valid", "owner", "writable", "symlink", "duplicate", "handler" }) do
            local entry = { version = 1, type = "fixture", handler = "oasis.test.fixture_ui_handler",
                bindings = { { server = "fixture.server", method = "edit", operation = "edit" } } }
            if mode == "handler" then entry.handler = "../../tmp/handler" end
            local raw = jsonc.stringify(entry, false)
            replace(t, "nixio.fs", {
                lstat = function(path)
                    if path:match("%.json$") then
                        return { type = mode == "symlink" and "lnk" or "reg", size = #raw,
                            uid = mode == "owner" and 1000 or 0,
                            modestr = mode == "writable" and "rw-rw-r--" or "rw-r--r--" }
                    end
                    return { type = "dir", uid = 0, modestr = "rwxr-xr-x" }
                end,
                readfile = function() return raw end,
                dir = function()
                    local index = 0
                    local names = mode == "duplicate" and { "a.json", "b.json" } or { "a.json" }
                    return function() index = index + 1; return names[index] end
                end,
            })
            replace(t, "oasis.ui.registry", nil)
            local entries = require("oasis.ui.registry").load()
            if mode == "valid" then t:assert_type("table", entries.fixture)
            else t:assert_nil(entries) end
        end
    end)
end

return M
