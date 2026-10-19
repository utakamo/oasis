local jsonc = require("luci.jsonc")
local M = {}

local function replace(t, name, value)
    local old = package.loaded[name]
    package.loaded[name] = value
    t:on_cleanup(function() package.loaded[name] = old end)
end

local function copy(value) return jsonc.parse(jsonc.stringify(value, false)) end

local function fixture(t)
    local env = { revision = 1, commits = 0, reloads = 0, locks = 0, closes = 0,
        db = {
            radio0 = { [".type"] = "wifi-device", band = "2g" },
            ap0 = { [".type"] = "wifi-iface", device = "radio0", mode = "ap", ssid = "Existing",
                encryption = "psk2", key = "PRIVATE_EXISTING_KEY" },
        } }
    replace(t, "luci.model.uci", { cursor = function()
        local data = copy(env.db)
        return {
            unload = function() end,
            load = function() data = copy(env.db); return true end,
            foreach = function(_, _, kind, callback)
                for name, value in pairs(data) do
                    if value[".type"] == kind then
                        local section = copy(value); section[".name"] = name; callback(section)
                    end
                end
            end,
            get_all = function(_, config, section)
                if config == "network" and section == "lan" then return {} end
                return data[section]
            end,
            set = function(_, _, section, key, value) data[section][key] = value; return true end,
            delete = function(_, _, section, key)
                if key then data[section][key] = nil else data[section] = nil end
                return true
            end,
            section = function(_, _, kind) data.ap1 = { [".type"] = kind }; return "ap1" end,
            commit = function()
                if env.commit_fail then return false end
                env.db = copy(data); env.commits = env.commits + 1; env.revision = env.revision + 1
                return true
            end,
            revert = function() data = copy(env.db) end,
        }
    end })
    replace(t, "nixio.fs", { stat = function() return { type = "reg", mtime = env.revision, ctime = env.revision, ino = 1, size = 100 } end })
    replace(t, "nixio", { open = function()
        env.locks = env.locks + 1
        return { seek = function() end, lock = function(_, mode) return mode ~= "tlock" or not env.busy end,
            close = function() env.closes = env.closes + 1 end }
    end })
    replace(t, "luci.sys", { exec = function()
        env.reloads = env.reloads + 1; return env.reload_fail and "1" or "0"
    end })
    replace(t, "luci.util", { trim = function(value) return value:match("^%s*(.-)%s*$") end })
    replace(t, "oasis.local.tool.wifi_config", nil)
    replace(t, "oasis.local.tool.ui.wifi_config", nil)
    env.backend = require("oasis.local.tool.wifi_config")
    env.handler = require("oasis.local.tool.ui.wifi_config")
    function env.payload()
        return { revision = env.backend.load("update").revision, operation = "update",
            interfaces = { { section = "ap0", ssid = "Changed", encryption = "psk2", passphrase = "" } } }
    end
    return env
end

function M.register(harness)
    harness:test("unit", "Wi-Fi backend snapshots omit keys and updates preserve an unchanged key", function(t)
        local env = fixture(t)
        local snapshot = env.backend.load("update")
        t:assert_true(snapshot.ok)
        t:assert_not_contains(jsonc.stringify(snapshot), "PRIVATE_EXISTING_KEY")
        t:assert_equal(0, env.locks)
        local result = env.backend.apply(env.payload())
        t:assert_true(result.ok)
        t:assert_true(result.saved)
        t:assert_equal("PRIVATE_EXISTING_KEY", env.db.ap0.key)
        t:assert_equal("Changed", env.db.ap0.ssid)
        t:assert_equal(1, env.commits)
        t:assert_equal(1, env.reloads)
        t:assert_equal(env.locks, env.closes)
    end)

    harness:test("unit", "Wi-Fi backend rejects stale revisions, invalid encryption, short keys and busy locks", function(t)
        for _, mode in ipairs({ "revision", "encryption", "key", "busy", "commit" }) do
            local env = fixture(t)
            local payload = env.payload()
            if mode == "revision" then env.revision = 2
            elseif mode == "encryption" then payload.interfaces[1].encryption = "unsupported"
            elseif mode == "key" then payload.interfaces[1].passphrase = "short"
            elseif mode == "busy" then env.busy = true
            else env.commit_fail = true end
            t:assert_false(env.backend.apply(payload).ok)
            t:assert_equal(0, env.commits)
            t:assert_equal(0, env.reloads)
            t:assert_equal(env.locks, env.closes)
            t:assert_equal("Existing", env.db.ap0.ssid)
        end
    end)

    harness:test("unit", "Wi-Fi backend supports add, delete and saved-but-reload-failed results", function(t)
        local env = fixture(t)
        local payload = { revision = env.backend.load("add", "2G").revision, operation = "add", band = "2G",
            device = "radio0", ssid = "New", encryption = "psk2", passphrase = "new-password" }
        t:assert_true(env.backend.apply(payload).ok)
        t:assert_equal("New", env.db.ap1.ssid)
        t:assert_equal("lan", env.db.ap1.network)
        env.reload_fail = true
        local result = env.backend.apply({ revision = env.backend.load("delete").revision,
            operation = "delete", section = "ap1" })
        t:assert_false(result.ok)
        t:assert_true(result.saved)
        t:assert_nil(env.db.ap1)
    end)

    harness:test("unit", "Wi-Fi form steps validate credentials before confirmation without writing settings", function(t)
        local env = fixture(t)
        local state, step = env.handler.prepare({ type = "wifi_config", version = 1, operation = "add", band = "2G" },
            { arguments = { band = "2G" } })
        t:assert_type("table", step.form)
        step = env.handler.advance(state, { device = "radio0", ssid = "New", encryption = "psk2" })
        t:assert_equal("secret", step.form.fields[1].type)
        step = env.handler.advance(state, { passphrase = "short" })
        t:assert_true(step.retry)
        step = env.handler.advance(state, { passphrase = "new-password" })
        t:assert_true(step.ready)
        t:assert_equal(0, env.commits)
        t:assert_equal(0, env.locks)
        t:assert_true(env.handler.apply(state).ok)
    end)
end

return M
