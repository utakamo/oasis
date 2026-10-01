"""Host fixtures for the embedded hook; no live UCI, services, or router paths.

Run with: python3 -m unittest discover -s dev_tools/tests -v
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_tool_edge_account import UCI_FIXTURE, module_preload


HOOK = Path(__file__).resolve().parents[2] / "oasis-tool-edge/postrm.sh"
LUA_FIXTURE = r'''
local scenario = os.getenv("OASIS_POSTRM_CASE")
local marker = os.getenv("OASIS_POSTRM_MARKER")
local function event(value)
    local log = assert(io.open(os.getenv("OASIS_POSTRM_EVENTS"), "a"))
    log:write(value .. "\n")
    log:close()
end
local real_open = io.open
io.open = function(path, mode)
    local content
    if path == "/proc/300/stat" then
        content = "300 (fixture worker) S 200" .. string.rep(" 0", 17) .. " 33 0\n"
    elseif path == "/proc/200/stat" then
        content = "200 (fixture helper) S 1" .. string.rep(" 0", 17) .. " 22 0\n"
    elseif path == "/tmp/oasis-tool-edge-upgrade/200-22" then
        content = marker == "stale" and "200 21 oasis-tool-edge\n"
            or "200 22 oasis-tool-edge\n"
    else
        assert(path == os.getenv("OASIS_POSTRM_EVENTS"), "Unexpected file access")
        return real_open(path, mode)
    end
    return { read = function() return content end, close = function() end }
end
package.preload["nixio"] = function()
    return {
        getpid = function() return 300 end,
        open = function(path, mode, permissions)
            assert(path == "/var/lock/oasis-tool-edge-account.lock" or path == "/var/lock/oasis-settings.lock")
            assert(mode == "a" and permissions == "0600")
            return {
                seek = function() return 0 end,
                lock = function(_, operation)
                    assert(operation == "tlock")
                    return not (scenario == "locked" and path == "/var/lock/oasis-tool-edge-account.lock")
                        and not (scenario == "settings_locked" and path == "/var/lock/oasis-settings.lock")
                end,
                close = function() event("unlock") end
            }
        end
    }
end
package.preload["nixio.fs"] = function()
    return {
        lstat = function(path)
            if path == "/tmp/oasis-tool-edge-upgrade" and marker ~= "none" then
                return {type = "dir", uid = marker == "untrusted" and 1000 or 0,
                    modedec = marker == "public" and 755 or 700}
            elseif path == "/tmp/oasis-tool-edge-upgrade/200-22"
                and (marker == "valid" or marker == "stale" or marker == "symlink") then
                return {type = marker == "symlink" and "lnk" or "reg", uid = 0, modedec = 600}
            end
            -- "reused" and "unrelated" markers belong to different processes.
            return nil
        end,
        access = function(path, mode)
            assert(path == "/etc/config/oasis" or path == "/etc/init.d/rpcd")
            return true
        end
    }
end
os.execute = function(command)
    assert(command == "/etc/init.d/rpcd restart >/dev/null 2>&1")
    event("restart")
    return scenario == "restart_failed" and 1 or 0
end
'''


@unittest.skipUnless(shutil.which("lua"), "Lua is required for hook fixtures")
class PostrmTests(unittest.TestCase):
    def run_hook(self, scenario="one", marker="none", fault=""):
        source = HOOK.read_text().split("lua - <<'LUA'\n", 1)[1].rsplit("\nLUA", 1)[0]
        with tempfile.TemporaryDirectory(prefix="oasis-postrm-test-") as directory:
            events_file = Path(directory) / "events"
            env = dict(os.environ, OASIS_POSTRM_CASE=scenario,
                       OASIS_POSTRM_MARKER=marker, OASIS_POSTRM_EVENTS=str(events_file),
                       OASIS_ACCOUNT_CASE=scenario, OASIS_ACCOUNT_FAIL=fault,
                       OASIS_ACCOUNT_EVENTS=str(events_file))
            wrapped = r'''
local actual_exit = os.exit
local status
os.exit = function(code) status = code; error("fixture_exit") end
local ok, err = pcall(function()
''' + source + r'''
end)
assert(status ~= nil, "Hook did not exit normally")
fixture.assert_unchanged()
if status == 0 and marker == "none" and scenario == "one" then
    assert(not fixture.managed())
    assert(fixture.persisted.oasis.rpc.oasis_rpc_account == nil)
end
if status == 1 and scenario ~= "read_failed" and scenario ~= "exception" then
    assert(fixture.managed() or scenario == "registry_without_account")
end
actual_exit(status)
'''
            result = subprocess.run(["lua", "-"], input=UCI_FIXTURE + module_preload() + LUA_FIXTURE + wrapped,
                                    env=env, capture_output=True, text=True, timeout=10)
            events = events_file.read_text().splitlines() if events_file.exists() else []
            return result, events

    def test_removal_deletes_only_the_single_marked_login(self):
        result, events = self.run_hook()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["delete:managed", "clear_registry", "commit:rpcd", "commit:oasis",
                          "disable", "commit:oasis", "unlock", "unlock", "restart"], events)

    def test_zero_or_multiple_markers_never_delete_a_login(self):
        for scenario in ("zero", "empty", "multiple"):
            with self.subTest(scenario=scenario):
                result, events = self.run_hook(scenario)
                self.assertEqual(1 if scenario == "multiple" else 0, result.returncode, result.stderr)
                self.assertFalse(any(event.startswith("delete:") for event in events))
                self.assertNotIn("commit:rpcd", events)
                self.assertIn("disable", events)
                self.assertEqual("restart", events[-1])

    def test_only_a_private_live_ancestor_marker_preserves_account(self):
        for marker in ("valid", "stale", "reused", "unrelated", "untrusted", "public", "symlink"):
            with self.subTest(marker=marker):
                result, events = self.run_hook(marker=marker)
                self.assertEqual(0, result.returncode, result.stderr)
                if marker == "valid":
                    self.assertEqual([], events)
                else:
                    self.assertIn("delete:managed", events)

    def test_failures_still_disable_support_and_restart_rpcd(self):
        for scenario in ("locked", "read_failed", "exception", "delete_failed",
                         "commit_failed", "restart_failed"):
            with self.subTest(scenario=scenario):
                result, events = self.run_hook(scenario)
                self.assertEqual(1, result.returncode, result.stderr)
                self.assertIn("disable", events)
                self.assertEqual("restart", events[-1])
                if scenario in ("locked", "read_failed", "exception"):
                    self.assertNotIn("delete:managed", events)
                if scenario == "commit_failed":
                    self.assertIn("revert:rpcd", events)

    def test_missing_or_inconsistent_registry_does_not_delete_a_login(self):
        for scenario in ("registry_missing", "registry_empty", "registry_mismatch", "registry_unmarked",
                         "registry_without_account", "duplicate_username", "invalid_registry"):
            with self.subTest(scenario=scenario):
                result, events = self.run_hook(scenario)
                self.assertEqual(1, result.returncode, result.stderr)
                self.assertNotIn("delete:managed", events)
                self.assertNotIn("clear_registry", events)
                self.assertIn("disable", events)
                self.assertEqual("restart", events[-1])

    def test_registry_save_failure_restores_login_and_reports_failure(self):
        result, events = self.run_hook(fault="oasis:1")
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertIn("delete:managed", events)
        self.assertIn("add:rpcd", events)
        self.assertEqual("restart", events[-1])

    def test_busy_settings_lock_does_not_commit_pending_settings(self):
        result, events = self.run_hook("settings_locked")
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertNotIn("delete:managed", events)
        self.assertNotIn("commit:oasis", events)
        self.assertEqual("restart", events[-1])

    def test_offline_install_and_direct_upgrade_skip_the_hook(self):
        # Replace the Lua invocation so a missed guard cannot touch host state.
        source = HOOK.read_text().replace("lua - <<'LUA'", "exit 99\ncat <<'LUA'")
        for args, variables in ((["upgrade"], {}), (["remove"], {"PKG_UPGRADE": "1"}),
                                (["remove"], {"IPKG_INSTROOT": "/fixture"})):
            with self.subTest(args=args, variables=variables):
                env = dict(os.environ, IPKG_INSTROOT="", PKG_UPGRADE="")
                env.update(variables)
                result = subprocess.run(["/bin/sh", "-s", "--", *args], input=source,
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(0, result.returncode, result.stderr)


if __name__ == "__main__":
    unittest.main()
