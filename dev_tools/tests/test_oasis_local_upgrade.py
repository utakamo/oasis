"""Safe host tests: python3 -m unittest discover -s dev_tools/tests -v.

Only temporary copies run. Every router path is redirected into a temporary
directory and package/configuration commands are replaced with fixtures.
Neither the actual router helpers nor a host package manager are executed.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
MOCK_COMMAND = r'''
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys

root = Path(os.environ["OASIS_UPGRADE_TEST_ROOT"])
command = Path(sys.argv[0]).name
args = sys.argv[1:]
action = args[0] if args else ""
if command == "uci":
    action = "export" if args[0] == "export" else "import"
elif command == "cp":
    action = "backup" if args[-1] == str(root / "tmp/oasis/oasis.conf") else "restore"
elif command in ("opkg", "apk") and action in ("remove", "del"):
    markers = list((root / "tmp/oasis-tool-edge-upgrade").glob("*"))
    if args[1] == "oasis-tool-edge":
        assert len(markers) == 1, "Tool Edge removal must have one upgrade marker"
        marker = markers[0]
        assert marker.stat().st_mode & 0o777 == 0o600
        assert marker.parent.stat().st_mode & 0o777 == 0o700
        pid, start_time, package = marker.read_text().split()
        assert package == "oasis-tool-edge"
        assert marker.name == pid + "-" + start_time
        fields = Path("/proc/" + pid + "/stat").read_text().rsplit(") ", 1)[1].split()
        assert fields[19] == start_time
        assert int(pid) == os.getppid(), "Marker must belong to this helper"
        action += "-edge"
    else:
        assert not markers, "Only Tool Edge removal may retain the account"
elif command == "stat":
    # Reproduce OpenWrt without the optional stat command.
    action = "unavailable"
elif command == "lua":
    assert args[0] == "-" and len(args) == 4
    action = "check-" + args[2]
event = command + ":" + action
with (root / "events").open("a") as log:
    log.write(event + "\n")
if os.environ.get("OASIS_UPGRADE_TEST_FAIL") == event:
    sys.exit(1)
if os.environ.get("OASIS_UPGRADE_TEST_FAIL") == event + "-signal":
    os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(1)
if command == "stat":
    sys.exit(127)
elif command == "lua":
    path = Path(args[1])
    assert path.is_relative_to(root)
    metadata = path.lstat()
    kind = ("dir" if stat.S_ISDIR(metadata.st_mode)
            else "reg" if stat.S_ISREG(metadata.st_mode) else "lnk")
    permissions = int(format(metadata.st_mode & 0o7777, "o"))
    # Model root ownership when the developer runs these fixtures unprivileged.
    uid = 0
    fault = os.environ.get("OASIS_UPGRADE_TEST_PERMISSIONS", "")
    if fault == args[2] + ":owner":
        uid = 1000
    elif fault == args[2] + ":public":
        permissions = 755 if kind == "dir" else 644
    elif fault == args[2] + ":symlink":
        kind = "lnk"
    fixture = 'package.preload["nixio.fs"] = function() return {lstat = function(path)\n'
    fixture += 'assert(path == arg[1])\n'
    fixture += 'return {type = "' + kind + '", uid = ' + str(uid)
    fixture += ', modedec = ' + str(permissions) + '} end} end\n'
    result = subprocess.run([os.environ["OASIS_UPGRADE_TEST_LUA"], *args],
                            input=fixture + sys.stdin.read(), text=True)
    sys.exit(result.returncode)
elif command == "uci":
    if action == "export":
        print("old schema")
    else:
        assert args == ["-f", str(root / "tmp/oasis/backup"), "import", "oasis"]
        (root / "registry").write_text(Path(args[1]).read_text().strip())
        (root / "account_registry").unlink(missing_ok=True)
elif command == "cp":
    shutil.copyfile(args[-2], args[-1])
elif command in ("opkg", "apk"):
    if action == "status":
        print("Status: install ok installed")
    elif action in ("install", "add"):
        # Model the postinst migration before keep-config restores old UCI.
        (root / "registry").write_text("new schema")
        (root / "initialized").touch()
        # Model the core package's account migration before config restore.
        (root / "account_registry").write_text("fixture-managed-user")
elif command == "oasis_tool_edge_account":
    assert args == ["migrate"]
    assert (root / "initialized").exists()
    (root / "account_registry").write_text("fixture-managed-user")
elif command == "oasis_tool_setup":
    assert args == ["refresh-package-manifests"]
    assert (root / "initialized").exists()
    assert (root / "registry").read_text() == "old schema"
    (root / "registry").write_text("new schema")
elif command == "rpcd":
    assert args == ["restart"]
    assert (root / "registry").read_text() == "new schema"
    assert (root / "account_registry").read_text() == "fixture-managed-user"
else:
    raise AssertionError("Unexpected command: " + command)
'''


@unittest.skipUnless(shutil.which("lua"), "Lua is required for permission fixtures")
class UpgradeTests(unittest.TestCase):
    def run_helper(self, package_format, mode="keep-config", fail="", permissions=""):
        with tempfile.TemporaryDirectory(prefix="oasis-upgrade-test-") as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            (root / "tmp").mkdir()
            (root / "etc/oasis").mkdir(parents=True)
            (root / "etc/oasis/oasis.conf").write_text("fixture settings\n")
            for name in ("opkg", "apk", "uci", "cp", "rpcd", "oasis_tool_setup", "stat", "lua", "oasis_tool_edge_account"):
                mock = fake_bin / name
                mock.write_text("#!" + sys.executable + "\n" + MOCK_COMMAND)
                mock.chmod(0o700)

            name = "oasis_local_upgrade" + ("_apk" if package_format == "apk" else "")
            source = (REPOSITORY / "dev_tools" / name).read_text()
            router_paths = {
                "/tmp/oasis-tool-edge-upgrade": root / "tmp/oasis-tool-edge-upgrade",
                "/tmp/oasis": root / "tmp/oasis",
                "/etc/oasis": root / "etc/oasis",
                "/usr/bin/oasis_tool_setup": fake_bin / "oasis_tool_setup",
                "/usr/bin/oasis_tool_edge_account": fake_bin / "oasis_tool_edge_account",
                "/etc/init.d/rpcd": fake_bin / "rpcd",
            }
            for router_path in router_paths:
                self.assertIn(router_path, source)
            source = re.sub("|".join(re.escape(path) for path in router_paths),
                            lambda match: str(router_paths[match.group()]), source)
            # No additional absolute router paths may escape the test mapping.
            unmapped = source.replace(str(root), "<fixture>")
            self.assertNotIn(" /etc/", unmapped)
            self.assertNotIn(" /usr/", unmapped)
            self.assertNotIn(" /tmp/oasis", unmapped)
            helper = root / "helper.sh"
            helper.write_text(source)
            for package in ("oasis", "luci-app-oasis", "oasis-mod-tool", "oasis-mod-agent",
                            "oasis-mod-retired", "oasis-tool-edge", "oasis-mod-test", "oasis-tool-maker"):
                filename = (package + "_1.0-r1_all.ipk" if package_format == "ipk"
                            else package + "-1.0-r1.apk")
                (root / filename).write_text("fixture artifact")
            env = {
                "PATH": str(fake_bin) + os.pathsep + os.defpath,
                "OASIS_UPGRADE_TEST_ROOT": str(root),
                "OASIS_UPGRADE_TEST_FAIL": fail,
                "OASIS_UPGRADE_TEST_PERMISSIONS": permissions,
                "OASIS_UPGRADE_TEST_LUA": shutil.which("lua"),
            }
            result = subprocess.run(["/bin/sh", str(helper), mode], cwd=root,
                                    env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual([], list((root / "tmp/oasis-tool-edge-upgrade").glob("*")),
                             "Upgrade marker must be cleared on success or failure")
            events = (root / "events").read_text().splitlines()
            self.assertNotIn("stat:unavailable", events, "Helpers must work without stat")
            registry = (root / "registry").read_text() if (root / "registry").exists() else None
            return result, events, registry

    def test_restore_reconciles_schemas_after_postinst_marker(self):
        for package_format in ("ipk", "apk"):
            with self.subTest(format=package_format):
                result, events, registry = self.run_helper(package_format)
                self.assertEqual(0, result.returncode, result.stderr)
                install = "opkg:install" if package_format == "ipk" else "apk:add"
                refresh = "oasis_tool_setup:refresh-package-manifests"
                migrate = "oasis_tool_edge_account:migrate"
                self.assertEqual(8, events.count(install))
                self.assertLess(max(i for i, e in enumerate(events) if e == install), events.index("uci:import"))
                self.assertLess(events.index("cp:restore"), events.index(migrate))
                self.assertLess(events.index(migrate), events.index(refresh))
                self.assertLess(events.index(refresh), events.index("rpcd:restart"))
                self.assertEqual(1, events.count(refresh))
                self.assertEqual("new schema", registry)

    def test_normal_install_does_not_run_restore_reconciliation(self):
        for package_format in ("ipk", "apk"):
            with self.subTest(format=package_format):
                result, events, registry = self.run_helper(package_format, mode="")
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertNotIn("uci:import", events)
                self.assertNotIn("oasis_tool_edge_account:migrate", events)
                self.assertNotIn("oasis_tool_setup:refresh-package-manifests", events)
                self.assertIn("rpcd:restart", events)
                self.assertEqual("new schema", registry)

    def test_backup_failures_stop_before_package_removal(self):
        for package_format in ("ipk", "apk"):
            for fail in ("uci:export", "cp:backup"):
                with self.subTest(format=package_format, fail=fail):
                    result, events, _ = self.run_helper(package_format, fail=fail)
                    self.assertNotEqual(0, result.returncode)
                    self.assertFalse(any(e.startswith(("apk:", "opkg:")) for e in events))
                    self.assertNotIn("rpcd:restart", events)

    def test_restore_failures_stop_before_reconciliation(self):
        for package_format in ("ipk", "apk"):
            for fail in ("uci:import", "cp:restore"):
                with self.subTest(format=package_format, fail=fail):
                    result, events, _ = self.run_helper(package_format, fail=fail)
                    self.assertNotEqual(0, result.returncode)
                    self.assertNotIn("oasis_tool_setup:refresh-package-manifests", events)
                    self.assertNotIn("rpcd:restart", events)

    def test_reconciliation_failure_is_not_reported_as_success(self):
        for package_format in ("ipk", "apk"):
            with self.subTest(format=package_format):
                result, events, registry = self.run_helper(
                    package_format, fail="oasis_tool_setup:refresh-package-manifests")
                self.assertNotEqual(0, result.returncode)
                self.assertIn("configuration restore", result.stderr)
                self.assertNotIn("rpcd:restart", events)
                self.assertEqual("old schema", registry)

    def test_install_failure_stops_before_restore(self):
        for package_format in ("ipk", "apk"):
            with self.subTest(format=package_format):
                fail = "opkg:install" if package_format == "ipk" else "apk:add"
                result, events, _ = self.run_helper(package_format, fail=fail)
                self.assertNotEqual(0, result.returncode)
                self.assertNotIn("uci:import", events)
                self.assertNotIn("rpcd:restart", events)

    def test_rpcd_failure_is_not_reported_as_success(self):
        for package_format in ("ipk", "apk"):
            with self.subTest(format=package_format):
                result, _, registry = self.run_helper(package_format, fail="rpcd:restart")
                self.assertNotEqual(0, result.returncode)
                self.assertIn("Failed to restart rpcd", result.stderr)
                self.assertEqual("new schema", registry)

    def test_edge_removal_failure_clears_marker_and_stops_upgrade(self):
        for package_format in ("ipk", "apk"):
            event = "opkg:remove-edge" if package_format == "ipk" else "apk:del-edge"
            for fail in (event, event + "-signal"):
                with self.subTest(format=package_format, fail=fail):
                    result, events, _ = self.run_helper(package_format, fail=fail)
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(event, events)
                    self.assertNotIn("opkg:install", events)
                    self.assertNotIn("apk:add", events)
                    self.assertNotIn("rpcd:restart", events)

    def test_unsafe_marker_permissions_stop_before_edge_removal(self):
        for package_format in ("ipk", "apk"):
            for permissions in ("dir:owner", "dir:public", "dir:symlink", "reg:public"):
                with self.subTest(format=package_format, permissions=permissions):
                    result, events, _ = self.run_helper(package_format, permissions=permissions)
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn("private Tool Edge upgrade marker", result.stderr)
                    self.assertNotIn("opkg:remove-edge", events)
                    self.assertNotIn("apk:del-edge", events)
                    self.assertNotIn("opkg:install", events)
                    self.assertNotIn("apk:add", events)

    def test_registry_migration_failure_stops_before_manifest_refresh(self):
        for package_format in ("ipk", "apk"):
            with self.subTest(format=package_format):
                result, events, _ = self.run_helper(package_format, fail="oasis_tool_edge_account:migrate")
                self.assertNotEqual(0, result.returncode)
                self.assertIn("RPC account registry after configuration restore", result.stderr)
                self.assertNotIn("oasis_tool_setup:refresh-package-manifests", events)
                self.assertNotIn("rpcd:restart", events)


if __name__ == "__main__":
    unittest.main()
