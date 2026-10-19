#!/usr/bin/env python3
"""Exercise the router's BusyBox secret reader in a real pseudo-terminal."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import termios
import time
import unittest


READER = Path(__file__).resolve().parents[2] / "oasis/files/usr/libexec/oasis-read-secret"


@unittest.skipUnless(shutil.which("busybox"), "BusyBox is required")
class SecretInputTest(unittest.TestCase):
    def run_reader(self, action):
        master, slave = pty.openpty()

        def child_terminal():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

        process = subprocess.Popen(
            ["busybox", "sh", str(READER)], stdin=slave, stderr=slave,
            stdout=subprocess.PIPE, preexec_fn=child_terminal,
        )
        try:
            deadline = time.monotonic() + 3
            while termios.tcgetattr(slave)[3] & termios.ECHO:
                if process.poll() is not None or time.monotonic() > deadline:
                    self.fail("secret reader did not disable echo")
                time.sleep(0.01)
            action(master, process)
            output, _ = process.communicate(timeout=3)
            self.assertTrue(termios.tcgetattr(slave)[3] & termios.ECHO, "echo was not restored")
            visible = b""
            while select.select([master], [], [], 0)[0]:
                visible += os.read(master, 4096)
            self.assertNotIn(b"private-fixture-value", visible)
            return output, process.returncode
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)
            os.close(slave)

    def test_secret_uses_pipe_and_restores_echo(self):
        output, code = self.run_reader(lambda fd, _: os.write(fd, b"private-fixture-value\n"))
        self.assertEqual(output, b"ok:private-fixture-value\n")
        self.assertEqual(code, 0)

    def test_eof_restores_echo(self):
        output, code = self.run_reader(lambda fd, _: os.write(fd, b"\x04"))
        self.assertEqual(output, b"")
        self.assertNotEqual(code, 0)

    def test_ctrl_c_restores_echo(self):
        output, code = self.run_reader(lambda fd, _: os.write(fd, b"\x03"))
        self.assertEqual(output, b"")
        self.assertNotEqual(code, 0)

    def test_termination_restores_echo(self):
        output, code = self.run_reader(lambda _, proc: os.killpg(proc.pid, signal.SIGTERM))
        self.assertEqual(output, b"")
        self.assertNotEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
