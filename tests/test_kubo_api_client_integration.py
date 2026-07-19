import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error

from kubo_api_client import KuboClient


class KuboDaemon:
    """Small test harness for a disposable offline Kubo daemon."""

    def __init__(self):
        self._tmpdir = tempfile.TemporaryDirectory(prefix="kubo-itest-")
        self.repo = Path(self._tmpdir.name) / "repo"
        self.port = self._free_port()
        self.api = f"http://127.0.0.1:{self.port}"
        self.process = None
        self.env = {**os.environ, "IPFS_PATH": str(self.repo)}

    def __enter__(self):
        ipfs = shutil.which("ipfs")
        if ipfs is None:
            raise unittest.SkipTest("ipfs (Kubo) executable is not installed")

        subprocess.run(
            [ipfs, "init", "--profile", "test"],
            env=self.env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        subprocess.run(
            [ipfs, "config", "Addresses.API", f"/ip4/127.0.0.1/tcp/{self.port}"],
            env=self.env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        subprocess.run(
            [ipfs, "config", "Addresses.Gateway", "/ip4/127.0.0.1/tcp/0"],
            env=self.env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        subprocess.run(
            [ipfs, "config", "--json", "Addresses.Swarm", "[]"],
            env=self.env,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

        self.process = subprocess.Popen(
            [ipfs, "daemon", "--offline"],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        self._wait_until_ready()
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        self._tmpdir.cleanup()

    @staticmethod
    def _free_port():
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]

    def _wait_until_ready(self):
        client = KuboClient(self.api, timeout=1)
        deadline = time.monotonic() + 30
        last_error = None
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                output = self.process.stdout.read() if self.process.stdout else ""
                raise RuntimeError(f"Kubo daemon exited early with {self.process.returncode}:\n{output}")
            try:
                client.version()
                return
            except (urllib.error.URLError, TimeoutError, OSError) as err:
                last_error = err
                time.sleep(0.25)
        raise TimeoutError(f"Timed out waiting for Kubo API at {self.api}: {last_error}")


class KuboClientIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.daemon_context = KuboDaemon()
        cls.daemon = cls.daemon_context.__enter__()
        cls.client = KuboClient(cls.daemon.api, timeout=10)

    @classmethod
    def tearDownClass(cls):
        cls.daemon_context.__exit__(None, None, None)

    def test_version_reaches_real_offline_daemon(self):
        version = self.client.version()

        self.assertIn("Version", version)
        self.assertTrue(version["Version"])

    def test_add_file_and_pin_round_trip_against_daemon(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "hello.txt"
            path.write_text("hello from integration tests\n", encoding="utf-8")

            add_result = self.client.add(path, pin=False, cid_version=1, raw_leaves=True)

        self.assertEqual(add_result.errors, [])
        self.assertIsNotNone(add_result.cid)
        self.assertEqual(len(add_result.entries), 1)
        self.assertEqual(add_result.entries[0].name, "hello.txt")
        self.assertEqual(add_result.entries[0].hash, add_result.cid)

        pin_result = self.client.pin_add(add_result.cid)

        self.assertEqual(pin_result.errors, [])
        self.assertIn(add_result.cid, pin_result.pins)
        self.assertEqual(pin_result.cid, add_result.cid)

    def test_add_wrapped_directory_returns_root_entry(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir) / "fixture"
            root.mkdir()
            (root / "alpha.txt").write_text("alpha", encoding="utf-8")
            (root / "nested").mkdir()
            (root / "nested" / "beta.txt").write_text("beta", encoding="utf-8")

            result = self.client.add(
                root,
                recursive=True,
                wrap_with_directory=True,
                pin=False,
                cid_version=1,
                raw_leaves=True,
            )

        self.assertEqual(result.errors, [])
        self.assertIsNotNone(result.cid)
        self.assertEqual(result.entries[-1].hash, result.cid)
        self.assertEqual(result.entries[-1].name, "")
        self.assertIn("fixture/alpha.txt", [entry.name for entry in result.entries])
        self.assertIn("fixture/nested/beta.txt", [entry.name for entry in result.entries])


if __name__ == "__main__":
    unittest.main()
