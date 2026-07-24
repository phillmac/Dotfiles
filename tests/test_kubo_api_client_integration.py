from __future__ import annotations

import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
import signal
import sys

from kubo_api_client import KuboClient, KuboErrorException


def _post_bytes(api: str, path: str, params: dict[str, str], timeout: float = 10) -> bytes:
    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(f"{api}{path}?{query}", data=b"", method="POST")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def _cat(api: str, cid: str, timeout: float = 10) -> bytes:
    return _post_bytes(api, "/api/v0/cat", {"arg": cid}, timeout=timeout)


def _wait_for_cat(api: str, cid: str, expected: bytes, timeout: float = 20) -> None:
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            if _cat(api, cid, timeout=2) == expected:
                return
        except Exception as exc:  # Kubo may not have imported the block yet.
            last_error = exc
            close = getattr(exc, "close", None)
            if close is not None:
                close()
        time.sleep(0.1)
    raise AssertionError(f"CID {cid} was not readable from {api}: {last_error}")


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
            except (KuboErrorException, urllib.error.URLError, TimeoutError, OSError) as err:
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


class RheaWasabiPebbleExportIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source_context = KuboDaemon()
        cls.destination_context = KuboDaemon()
        cls.source = cls.source_context.__enter__()
        try:
            cls.destination = cls.destination_context.__enter__()
        except Exception:
            cls.source_context.__exit__(None, None, None)
            raise
        cls.source_client = KuboClient(cls.source.api, timeout=10)

    @classmethod
    def tearDownClass(cls):
        cls.destination_context.__exit__(None, None, None)
        cls.source_context.__exit__(None, None, None)

    def _add_source_file(self, contents: bytes) -> str:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "payload.txt"
            path.write_bytes(contents)
            result = self.source_client.add(path, pin=False, cid_version=1, raw_leaves=True)
        self.assertEqual(result.errors, [])
        self.assertIsNotNone(result.cid)
        return result.cid or ""

    def test_rhea_wasabi_export_process_cid_streams_dag_between_kubo_apis(self):
        import rhea_wasabi_pebble_export as exporter

        contents = b"opaque car transfer through direct kubo rpc\n"
        cid = self._add_source_file(contents)
        with tempfile.TemporaryDirectory() as tmpdir:
            config = exporter.ExportConfig(
                source=exporter.KuboEndpoint.parse(self.source.api),
                destination=exporter.KuboEndpoint.parse(self.destination.api),
                retry_delay=0.1,
                lock_path=Path(tmpdir) / "export.lock",
                terminate_timeout=2.0,
                lock_poll_interval=0.05,
                hook=None,
                chunk_size=7,
                buffer_size=14,
                connect_timeout=5.0,
                read_timeout=10.0,
                write_timeout=10.0,
            )
            self.assertEqual(exporter.process_cid(cid, config), 0)
        self.assertEqual(_cat(self.destination.api, cid), contents)

    def test_fifo_worker_processes_queued_cid_through_same_rpc_exporter(self):
        contents = b"queued direct kubo rpc transfer\n"
        cid = self._add_source_file(contents)
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            queue_path = tmp / "rhea.wasabi.pebble.export.laptop.dag.queue"
            lock_path = tmp / "export.lock"
            env = {
                **os.environ,
                "IPFS_LAPTOP_API_SOCKET": self.source.api,
                "RHEA_IPFS_WASABI_SOCKET": self.destination.api,
                "IPFS_DAG_EXPORT_LOCK": str(lock_path),
                "IPFS_DAG_RETRY_DELAY": "0.1",
                "IPFS_DAG_CHUNK_SIZE": "5",
                "IPFS_DAG_BUFFER_SIZE": "10",
            }
            worker = subprocess.Popen(
                [sys.executable, str(Path("rhea_wasabi_pebble_export.py").resolve()), "fifo-worker", "--queue", str(queue_path)],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            try:
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline and not queue_path.exists():
                    self.assertIsNone(worker.poll())
                    time.sleep(0.05)
                self.assertTrue(queue_path.exists())
                with open(queue_path, "w", encoding="utf-8") as fifo:
                    fifo.write("\n")
                    fifo.write(f"{cid}\n")
                _wait_for_cat(self.destination.api, cid, contents, timeout=20)
            finally:
                worker.terminate()
                try:
                    worker.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.wait(timeout=5)
            self.assertIn(worker.returncode, (0, 130, 143, -signal.SIGTERM))


if __name__ == "__main__":
    unittest.main()
