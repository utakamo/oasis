"""Lua/UCI fixtures for account registry updates; no router commands run.

Run from the repository: python3 -m unittest discover -s dev_tools/tests -v.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ACCOUNT = ROOT / "oasis/files/usr/lib/lua/oasis/tool_edge/account.lua"
CONTROLLER = ROOT / "oasis/files/luci/controller/module.lua"
UCI_FIXTURE = r'''
local scenario = os.getenv("OASIS_ACCOUNT_CASE") or "one"
local fault = os.getenv("OASIS_ACCOUNT_FAIL") or ""
local function event(value)
    local log = assert(io.open(os.getenv("OASIS_ACCOUNT_EVENTS"), "a"))
    log:write(value .. "\n")
    log:close()
end
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
local function reload_anonymous_ids(config, sections, generation)
    if config ~= "rpcd" then return sections end
    local reloaded = {}
    local index = 0
    for name, section in pairs(sections) do
        if section[".anonymous"] then
            index = index + 1
            name = "cfg" .. generation .. "_" .. index
            section[".name"] = name
        end
        reloaded[name] = section
    end
    return reloaded
end
local persisted = {
    oasis = {
        rpc = {[".type"] = "rpc", [".name"] = "rpc", enable = "0", oasis_rpc_account = "edge-user"},
        support = {[".type"] = "support", [".name"] = "support", tool_edge = "1"},
        assist = {[".type"] = "basic", [".name"] = "assist", enable = "1"}
    },
    rpcd = {
        normal = {[".name"] = "normal", [".type"] = "login", username = "root",
            password = "fixture-root-hash", read = {"*"}, write = {"*"}},
        other_type = {[".name"] = "other_type", [".type"] = "settings", oasis_tool_edge = "1"},
        managed = {[".name"] = "managed", [".anonymous"] = true, [".type"] = "login",
            username = "edge-user", password = "fixture-edge-hash", oasis_tool_edge = "1",
            write = {"oasis-tool-edge"}}
    }
}
if scenario == "zero" or scenario == "empty" then
    persisted.rpcd.managed = nil
    persisted.oasis.rpc.oasis_rpc_account = ""
    if scenario == "empty" then persisted.rpcd = {} end
elseif scenario == "multiple" then
    persisted.rpcd.second = {[".name"] = "second", [".type"] = "login", username = "second-edge", oasis_tool_edge = "1"}
elseif scenario == "duplicate_username" then
    persisted.rpcd.normal.username = "edge-user"
elseif scenario == "registry_missing" or scenario == "legacy" then
    persisted.oasis.rpc.oasis_rpc_account = nil
elseif scenario == "registry_empty" then
    persisted.oasis.rpc.oasis_rpc_account = ""
elseif scenario == "registry_mismatch" then
    persisted.oasis.rpc.oasis_rpc_account = "another-user"
elseif scenario == "registry_unmarked" then
    persisted.rpcd.managed.oasis_tool_edge = nil
elseif scenario == "registry_without_account" then
    persisted.rpcd.managed = nil
elseif scenario == "invalid_registry" then
    persisted.oasis.rpc.oasis_rpc_account = {"edge-user"}
end
local original = copy(persisted)
local staged = copy(persisted)
local commits = {}
local next_section = 0
local uci = {}
function uci:get_all(config, section)
    if config == "rpcd" and scenario == "read_failed" then return false end
    if config == "rpcd" and scenario == "exception" then error("fixture read failure") end
    return copy(section and staged[config][section] or not section and staged[config])
end
function uci:foreach(config, kind, callback)
    for _, section in pairs(staged[config]) do
        if section[".type"] == kind and callback(copy(section)) == false then break end
    end
    return true
end
function uci:add(config, kind)
    next_section = next_section + 1
    local name = "new" .. next_section
    staged[config][name] = {[".name"] = name, [".type"] = kind, [".anonymous"] = true}
    event("add:" .. config)
    return name
end
function uci:set(config, section, option, value)
    if value == nil then
        staged[config][section] = {[".name"] = section, [".type"] = option}
        return true
    end
    if config == "oasis" and option == "oasis_rpc_account" then
        event("set_registry")
        if fault == "set_registry" then return false end
    elseif config == "oasis" and section == "support" then
        assert(option == "tool_edge" and value == "0")
        event("disable")
    end
    staged[config][section][option] = copy(value)
    return true
end
function uci:set_list(config, section, option, value)
    return self:set(config, section, option, value)
end
function uci:delete(config, section, option)
    if option then
        if config == "oasis" and option == "oasis_rpc_account" then event("clear_registry") end
        local existed = staged[config][section][option] ~= nil
        staged[config][section][option] = nil
        return existed
    end
    event("delete:" .. section)
    if scenario == "delete_failed" then return false end
    staged[config][section] = nil
    return true
end
function uci:commit(config)
    event("commit:" .. config)
    commits[config] = (commits[config] or 0) + 1
    local selected = config .. ":" .. commits[config]
    if fault == "throw:" .. selected then error("fixture commit failure") end
    if fault == "persist_throw:" .. selected then
        persisted[config] = reload_anonymous_ids(config, copy(staged[config]), commits[config])
        error("fixture lost commit response")
    end
    if fault == selected or fault == config .. ":all"
        or scenario == "commit_failed" and config == "rpcd" then return false end
    persisted[config] = reload_anonymous_ids(config, copy(staged[config]), commits[config])
    staged[config] = copy(persisted[config])
    return true
end
function uci:revert(config)
    event("revert:" .. config)
    staged[config] = copy(persisted[config])
    return true
end
package.preload["luci.model.uci"] = function() return {cursor = function() return uci end} end
fixture = {uci = uci, persisted = persisted, original = original, copy = copy, event = event}
function fixture.assert_unchanged()
    if original.rpcd.normal then
        assert(persisted.rpcd.normal.username == original.rpcd.normal.username)
        assert(persisted.rpcd.normal.password == original.rpcd.normal.password)
        assert(persisted.rpcd.normal.write[1] == "*")
    else
        assert(persisted.rpcd.normal == nil)
    end
    assert(persisted.oasis.rpc.enable == "0")
    assert(persisted.oasis.assist.enable == "1")
end
function fixture.managed()
    for _, section in pairs(persisted.rpcd) do
        if section[".type"] == "login" and section.oasis_tool_edge == "1" then return section end
    end
end
'''


def module_preload():
    return 'package.preload["oasis.tool_edge.account"] = function()\n' + ACCOUNT.read_text() + '\nend\n'


def controller_functions():
    source = CONTROLLER.read_text()
    result = r'''
local uci = fixture.uci
local tool_edge_account = require("oasis.tool_edge.account")
local SETTINGS_RPCD_CONFIG = "rpcd"
local SETTINGS_TOOL_EDGE_MARKER = "oasis_tool_edge"
local SETTINGS_TOOL_EDGE_ROLE = "oasis-tool-edge"
local function settings_string_option(section, option, fallback) return section[option] or fallback end
local function tool_edge_password_hash() return "fixture-new-hash" end
local function tool_edge_restart_rpcd() fixture.event("restart"); return true end
'''
    for name in ("tool_edge_find_account", "tool_edge_username_in_use",
                 "tool_edge_set_login_acl", "tool_edge_apply_update"):
        match = re.search(r"local function " + name + r"\([^\n]*\)[\s\S]*?\nend\n", source)
        assert match, name
        result += match.group()
    return result


@unittest.skipUnless(shutil.which("lua"), "Lua is required for account fixtures")
class AccountTests(unittest.TestCase):
    def run_lua(self, assertion, scenario="one", fault="", controller=False):
        with tempfile.TemporaryDirectory(prefix="oasis-account-test-") as directory:
            events = Path(directory) / "events"
            env = dict(os.environ, OASIS_ACCOUNT_CASE=scenario, OASIS_ACCOUNT_FAIL=fault,
                       OASIS_ACCOUNT_EVENTS=str(events))
            source = UCI_FIXTURE + module_preload()
            if controller:
                source += controller_functions()
            source += '\nlocal account = require("oasis.tool_edge.account")\n' + assertion
            result = subprocess.run(["lua", "-"], input=source, env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)

    def test_matching_registry_selects_the_managed_account(self):
        self.run_lua('local a, err, name = account.find(fixture.uci)\n'
                     'assert(a and not err and a.username == "edge-user" and name == a.username)')

    def test_inconsistent_registry_and_duplicates_are_rejected(self):
        for scenario in ("registry_missing", "registry_empty", "registry_mismatch", "registry_unmarked",
                         "registry_without_account", "multiple", "duplicate_username", "invalid_registry"):
            with self.subTest(scenario=scenario):
                self.run_lua('local a, err = account.find(fixture.uci)\nassert(not a and err)\n'
                             'local removed = account.remove(fixture.uci)\nassert(not removed)\n'
                             'fixture.assert_unchanged()', scenario)

    def test_migration_only_registers_a_unique_legacy_account(self):
        self.run_lua('assert(account.migrate(fixture.uci))\n'
                     'assert(fixture.persisted.oasis.rpc.oasis_rpc_account == "edge-user")\n'
                     'assert(fixture.managed().password == "fixture-edge-hash")\n'
                     'fixture.assert_unchanged()', "legacy")
        for scenario in ("registry_mismatch", "multiple", "duplicate_username", "registry_without_account"):
            with self.subTest(scenario=scenario):
                self.run_lua('assert(not account.migrate(fixture.uci))\nfixture.assert_unchanged()', scenario)

    def test_migration_save_failure_preserves_account_and_missing_record(self):
        self.run_lua('assert(not account.migrate(fixture.uci))\n'
                     'assert(fixture.persisted.oasis.rpc.oasis_rpc_account == nil)\n'
                     'assert(fixture.managed().password == "fixture-edge-hash")', "legacy", "oasis:1")

    def test_controller_create_rename_and_remove_sync_the_registry(self):
        self.run_lua('assert(tool_edge_apply_update({action="create", username="new-user", password="fixture"}))\n'
                     'assert(fixture.managed().username == "new-user")\n'
                     'assert(fixture.persisted.oasis.rpc.oasis_rpc_account == "new-user")\n'
                     'assert(tool_edge_apply_update({action="update", username="renamed-user"}))\n'
                     'assert(fixture.managed().username == "renamed-user")\n'
                     'assert(fixture.persisted.oasis.rpc.oasis_rpc_account == "renamed-user")\n'
                     'assert(tool_edge_apply_update({action="remove"}))\n'
                     'assert(not fixture.managed())\n'
                     'assert(fixture.persisted.oasis.rpc.oasis_rpc_account == nil)\n'
                     'fixture.assert_unchanged()', "zero", controller=True)

    def test_failed_controller_save_restores_both_configurations(self):
        for action, scenario in (("create", "zero"), ("update", "one"), ("remove", "one")):
            for fault in ("set_registry", "rpcd:1", "throw:rpcd:1", "persist_throw:rpcd:1",
                          "oasis:1", "throw:oasis:1", "persist_throw:oasis:1"):
                if action == "remove" and fault == "set_registry":
                    continue
                with self.subTest(action=action, fault=fault):
                    username = "" if action == "remove" else ', username="new-user", password="fixture"'
                    expected = ('assert(not fixture.managed())\n'
                                'assert(fixture.persisted.oasis.rpc.oasis_rpc_account == "")'
                                if scenario == "zero" else
                                'assert(fixture.managed().username == "edge-user")\n'
                                'assert(fixture.managed().password == "fixture-edge-hash")\n'
                                'assert(fixture.persisted.oasis.rpc.oasis_rpc_account == "edge-user")')
                    self.run_lua('assert(not tool_edge_apply_update({action="' + action + '"' + username + '}))\n'
                                 + expected + '\nfixture.assert_unchanged()', scenario, fault, controller=True)

    def test_removal_clears_only_the_matching_account_and_registry(self):
        self.run_lua('assert(account.remove(fixture.uci))\nassert(not fixture.managed())\n'
                     'assert(fixture.persisted.oasis.rpc.oasis_rpc_account == nil)\nfixture.assert_unchanged()')

    def test_rollback_failure_is_reported(self):
        self.run_lua('local old = fixture.uci:get_all("rpcd", "managed")\n'
                     'assert(fixture.uci:set("rpcd", "managed", "username", "new-user"))\n'
                     'local ok, err = account.save(fixture.uci, old, "new-user")\n'
                     'assert(not ok and err == "rollback_failed")', fault="rpcd:all")


if __name__ == "__main__":
    unittest.main()
