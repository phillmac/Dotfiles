#!/usr/bin/env python3
"""Synchronous Rhea Wasabi Pebble IPFS DAG exporter and FIFO worker."""
from __future__ import annotations

import argparse, fcntl, math, os, signal, stat, subprocess, sys, time, threading
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

DEFAULT_LOCK = os.path.expanduser("~/.var/run/rhea-wasabi-pebble-export-laptop-dag.lock")
DEFAULT_RETRY_DELAY = 300.0
DEFAULT_TERMINATE_TIMEOUT = 5.0
MAX_TERMINATE_TIMEOUT = 60.0
DEFAULT_LOCK_POLL_INTERVAL = 0.1
QUEUE_PATH = "rhea.wasabi.pebble.export.laptop.dag.queue"


def log(msg: str) -> None:
    print(f"{time.strftime('%c')} - {msg}", file=sys.stderr, flush=True)


def parse_nonnegative_finite_float(raw: str | None, *, default: float, maximum: float) -> float:
    if raw is None:
        return default
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return default
    if not math.isfinite(value) or value < 0:
        return default
    return min(value, maximum)


@dataclass(frozen=True)
class ExportConfig:
    laptop_socket: str
    rhea_socket: str
    source_image: str
    destination_image: str
    retry_delay: float
    lock_path: Path
    terminate_timeout: float
    lock_poll_interval: float
    hook: str | None

    @classmethod
    def from_env(cls) -> "ExportConfig":
        return cls(
            laptop_socket=os.environ.get("IPFS_LAPTOP_API_SOCKET", os.path.expanduser("~/.var/run/ipfs-laptop-api.sock")),
            rhea_socket=os.environ.get("RHEA_IPFS_WASABI_SOCKET", os.path.expanduser("~/.var/run/rhea-ipfs-wasabi.sock")),
            source_image=os.environ.get("LAPTOP_IPFS_CLI_IMAGE", "ipfs/go-ipfs:v0.8.0"),
            destination_image=os.environ.get("RHEA_IPFS_CLI_IMAGE", "ipfs/go-ipfs:v0.31.0"),
            retry_delay=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_RETRY_DELAY"), default=DEFAULT_RETRY_DELAY, maximum=86400.0),
            lock_path=Path(os.environ.get("IPFS_DAG_EXPORT_LOCK", DEFAULT_LOCK)).expanduser(),
            terminate_timeout=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_EXPORT_TERMINATE_TIMEOUT"), default=DEFAULT_TERMINATE_TIMEOUT, maximum=MAX_TERMINATE_TIMEOUT),
            lock_poll_interval=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_EXPORT_LOCK_POLL_INTERVAL"), default=DEFAULT_LOCK_POLL_INTERVAL, maximum=10.0),
            hook=os.environ.get("IPFS_DAG_EXPORT_SYNC_HOOK"),
        )


class ShutdownRequested(BaseException):
    def __init__(self, signum: int):
        super().__init__(signum); self.signum = signum


class Supervisor:
    def __init__(self, config: ExportConfig):
        self.config = config
        self.shutdown = threading.Event()
        self.signum: int | None = None
        self.pgid: int | None = None
        self.processes: list[subprocess.Popen[object]] = []
        self.sleep_proc: subprocess.Popen[object] | None = None
        self._old: dict[int, object] = {}

    def __enter__(self) -> "Supervisor":
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGINT, signal.SIGTERM):
                self._old[sig] = signal.getsignal(sig)
                signal.signal(sig, self._handler)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        for sig, old in self._old.items():
            signal.signal(sig, old)

    def _handler(self, signum: int, frame: object) -> None:
        self.signum = signum; self.shutdown.set()
        if self.pgid is not None:
            try: os.killpg(self.pgid, signal.SIGTERM)
            except ProcessLookupError: pass
        if self.sleep_proc is not None and self.sleep_proc.poll() is None:
            try: self.sleep_proc.terminate()
            except ProcessLookupError: pass
        raise ShutdownRequested(signum)

    def wait(self, seconds: float) -> bool:
        return self.shutdown.wait(seconds)

    def _descendants(self) -> set[int]:
        remaining = [p.pid for p in self.processes if p.pid]
        seen: set[int] = set()
        while remaining:
            pid = remaining.pop()
            try:
                out = subprocess.run(["pgrep", "-P", str(pid)], text=True, capture_output=True, timeout=1).stdout
            except Exception:
                out = ""
            for line in out.splitlines():
                try: child = int(line)
                except ValueError: continue
                if child not in seen:
                    seen.add(child); remaining.append(child)
        return seen

    def terminate_group(self) -> None:
        pgid = self.pgid
        if pgid is None:
            return
        descendants = self._descendants()
        log(f"Sending SIGTERM to export pipeline process group {pgid}")
        try: os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError: pass
        deadline = time.monotonic() + self.config.terminate_timeout
        while time.monotonic() < deadline:
            for proc in self.processes:
                proc.poll()
            try:
                os.killpg(pgid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        try:
            os.killpg(pgid, 0)
            group_alive = True
        except ProcessLookupError:
            group_alive = False
        if group_alive or any(p.poll() is None for p in self.processes):
            log(f"Grace period expired for export pipeline process group {pgid}")
            log(f"Sending SIGKILL to export pipeline process group {pgid}")
            descendants.update(self._descendants())
            try: os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError: pass
            for pid in descendants:
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
        for p in self.processes:
            try: p.wait(timeout=1)
            except subprocess.TimeoutExpired:
                try: p.kill()
                except ProcessLookupError: pass
                p.wait()
        log("Export pipeline cleanup completed")
        self.processes.clear(); self.pgid = None


def _popen(args: Sequence[str], **kwargs) -> subprocess.Popen[object]:
    return subprocess.Popen(list(args), close_fds=True, **kwargs)


def run_pipeline_once(cid: str, config: ExportConfig, sup: Supervisor) -> int:
    if config.hook:
        p = _popen([config.hook, cid], start_new_session=True)
        sup.pgid = p.pid; sup.processes = [p]
        try: return p.wait()
        except ShutdownRequested: sup.terminate_group(); raise
        finally:
            if p.poll() is None: sup.terminate_group()
            sup.processes = []; sup.pgid = None

    export_args = ["docker", "run", "--rm", "--log-driver", "none", "--mount", f"type=bind,src={config.laptop_socket},dst=/run/ipfs-laptop-api.sock", "--entrypoint", "/usr/local/bin/ipfs", config.source_image, "--api=/unix/run/ipfs-laptop-api.sock", "dag", "export", "--progress=false", cid]
    import_args = ["docker", "run", "--rm", "-i", "--log-driver", "none", "--mount", f"type=bind,src={config.rhea_socket},dst=/run/rhea-ipfs-wasabi.sock", "--entrypoint", "/usr/local/bin/ipfs", config.destination_image, "--api=/unix/run/rhea-ipfs-wasabi.sock", "dag", "import", "--pin-roots=false", "--allow-big-block"]
    exp = _popen(export_args, stdout=subprocess.PIPE, start_new_session=True)
    sup.pgid = exp.pid
    buf = _popen(["mbuffer", "-e"], stdin=exp.stdout, stdout=subprocess.PIPE, process_group=sup.pgid)
    if exp.stdout: exp.stdout.close()
    imp = _popen(import_args, stdin=buf.stdout, process_group=sup.pgid)
    if buf.stdout: buf.stdout.close()
    sup.processes = [exp, buf, imp]
    try:
        rc_imp, rc_buf, rc_exp = imp.wait(), buf.wait(), exp.wait()
    except ShutdownRequested:
        sup.terminate_group(); raise
    finally:
        if any(p.poll() is None for p in sup.processes): sup.terminate_group()
    for name, rc in (("export", rc_exp), ("mbuffer", rc_buf), ("import", rc_imp)):
        if rc != 0: log(f"{name} stage failed with exit status {rc}")
    sup.processes = []; sup.pgid = None
    return 0 if rc_exp == rc_buf == rc_imp == 0 else 1


def acquire_lock_interruptibly(lock_fd: int, config: ExportConfig, sup: Supervisor) -> None:
    while not sup.shutdown.is_set():
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB); return
        except BlockingIOError:
            if sup.wait(config.lock_poll_interval): break
    raise ShutdownRequested(sup.signum or signal.SIGTERM)


def process_cid(cid: str, config: ExportConfig | None = None) -> int:
    config = config or ExportConfig.from_env()
    config.lock_path.parent.mkdir(parents=True, exist_ok=True)
    with Supervisor(config) as sup:
        with open(config.lock_path, "a+b", buffering=0) as lock_file:
            os.set_inheritable(lock_file.fileno(), False)
            acquire_lock_interruptibly(lock_file.fileno(), config, sup)
            while not sup.shutdown.is_set():
                log(f"Exporting {cid} from laptop and importing to rhea")
                try: status = run_pipeline_once(cid, config, sup)
                except ShutdownRequested as exc: return 128 + exc.signum
                if status == 0:
                    log(f"Done {cid}"); return 0
                log(f"Failed {cid}; retrying in {config.retry_delay:g} seconds")
                sleep_proc = _popen(["sleep", str(config.retry_delay)])
                sup.sleep_proc = sleep_proc
                try:
                    sleep_proc.wait()
                except ShutdownRequested:
                    if sleep_proc.poll() is None:
                        sleep_proc.terminate()
                        try: sleep_proc.wait(timeout=1)
                        except subprocess.TimeoutExpired:
                            sleep_proc.kill(); sleep_proc.wait()
                    return 128 + (sup.signum or signal.SIGTERM)
                finally:
                    if sup.sleep_proc is sleep_proc:
                        sup.sleep_proc = None
                if sup.shutdown.is_set(): break
            return 128 + (sup.signum or signal.SIGTERM)


def run_fifo_worker(queue_path: Path = Path(QUEUE_PATH), config: ExportConfig | None = None) -> int:
    config = config or ExportConfig.from_env()
    if queue_path.exists() and not stat.S_ISFIFO(queue_path.stat().st_mode):
        print(f"{queue_path} exists but is not a FIFO", file=sys.stderr); return 1
    if not queue_path.exists(): os.mkfifo(queue_path)
    with Supervisor(config) as sup:
        log(f"Waiting for CIDs on {queue_path}")
        while not sup.shutdown.is_set():
            try:
                with open(queue_path, "r") as fifo:
                    for line in fifo:
                        if sup.shutdown.is_set(): break
                        cid = line.strip()
                        if cid: 
                            rc = process_cid(cid, config)
                            if rc in (130,143): return rc
            except ShutdownRequested as exc:
                return 128 + exc.signum
    return 128 + (sup.signum or signal.SIGTERM)


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) == 1 and argv[0] not in {"-h", "--help", "export", "fifo-worker"}:
        try:
            return process_cid(argv[0])
        except ShutdownRequested as exc:
            return 128 + exc.signum
        except Exception as exc:
            print(f"Error: {exc}", file=sys.stderr); return 1
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    ex = sub.add_parser("export"); ex.add_argument("cid")
    fw = sub.add_parser("fifo-worker"); fw.add_argument("--queue", default=QUEUE_PATH)
    ns = p.parse_args(argv)
    try:
        if ns.cmd == "fifo-worker": return run_fifo_worker(Path(ns.queue))
        return process_cid(ns.cid)
    except ShutdownRequested as exc:
        return 128 + exc.signum
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr); return 1

if __name__ == "__main__":
    raise SystemExit(main())
