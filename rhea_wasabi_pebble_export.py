#!/usr/bin/env python3
"""Direct Kubo RPC DAG exporter and FIFO worker.

Streams an opaque CAR from a source Kubo /api/v0/dag/export response to a
bounded in-memory queue, then into a destination Kubo /api/v0/dag/import
streaming multipart/form-data request.  No Docker, ipfs CLI, mbuffer, CAR files,
or complete-CAR buffering are used by the built-in exporter.
"""
from __future__ import annotations

import argparse, contextlib, fcntl, http.client, json, math, os, queue, secrets, signal, socket, stat, subprocess, sys, threading, time, urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

DEFAULT_LOCK = os.path.expanduser("~/.var/run/rhea-wasabi-pebble-export-laptop-dag.lock")
DEFAULT_RETRY_DELAY = 300.0
DEFAULT_TERMINATE_TIMEOUT = 5.0
MAX_TRANSFER_CLEANUP_TIMEOUT = 60.0
EXPORTER_CLEANUP_MARGIN = 2.0
MAX_OUTER_EXPORTER_CLEANUP_TIMEOUT = MAX_TRANSFER_CLEANUP_TIMEOUT + EXPORTER_CLEANUP_MARGIN
MAX_TERMINATE_TIMEOUT = MAX_TRANSFER_CLEANUP_TIMEOUT
DEFAULT_LOCK_POLL_INTERVAL = 0.1
DEFAULT_CHUNK_SIZE = 1048576
DEFAULT_BUFFER_SIZE = 67108864
DEFAULT_CONNECT_TIMEOUT = 10.0
DEFAULT_READ_TIMEOUT = None
DEFAULT_WRITE_TIMEOUT = None
ERROR_SNIPPET_LIMIT = 65536
QUEUE_PATH = "rhea.wasabi.pebble.export.laptop.dag.queue"
_EOF = object()


def log(msg: str) -> None:
    print(f"{time.strftime('%c')} - {msg}", file=sys.stderr, flush=True)


def parse_nonnegative_finite_float(raw: str | None, *, default: float | None, maximum: float | None = None) -> float | None:
    if raw is None or raw == "":
        return default
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return default
    if not math.isfinite(value) or value < 0:
        return default
    return min(value, maximum) if maximum is not None else value


def parse_positive_finite_float(raw: str | None, *, default: float, maximum: float | None = None) -> float:
    value = parse_nonnegative_finite_float(raw, default=default, maximum=maximum)
    if value is None or value <= 0:
        return default
    return value


def exporter_cleanup_timeout_from_environment() -> float:
    inner = parse_nonnegative_finite_float(
        os.environ.get("IPFS_DAG_EXPORT_TERMINATE_TIMEOUT"),
        default=DEFAULT_TERMINATE_TIMEOUT,
        maximum=MAX_TRANSFER_CLEANUP_TIMEOUT,
    )
    assert inner is not None
    return min(inner + EXPORTER_CLEANUP_MARGIN, MAX_OUTER_EXPORTER_CLEANUP_TIMEOUT)


def _parse_positive_int(raw: str | None, *, default: int) -> int:
    try:
        value = int(raw) if raw not in (None, "") else default
    except ValueError:
        return default
    return value if value > 0 else default


@dataclass(frozen=True)
class KuboEndpoint:
    base_url: str
    unix_socket: Path | None

    @classmethod
    def parse(cls, value: str) -> "KuboEndpoint":
        expanded = os.path.expanduser(value)
        parsed = urllib.parse.urlparse(expanded)
        if parsed.scheme in {"http", "https"} and parsed.netloc:
            return cls(expanded.rstrip("/"), None)
        if parsed.scheme or parsed.netloc:
            raise ValueError(f"Malformed Kubo API endpoint: {value}")
        if not expanded.startswith("/"):
            raise ValueError(f"Unix-domain Kubo API socket path must be absolute: {value}")
        return cls("http://kubo.local", Path(expanded))

    def display(self) -> str:
        return f"unix://{self.unix_socket}" if self.unix_socket else self.base_url


@dataclass(frozen=True)
class ExportConfig:
    source: KuboEndpoint
    destination: KuboEndpoint
    retry_delay: float
    lock_path: Path
    terminate_timeout: float
    lock_poll_interval: float
    hook: str | None
    chunk_size: int
    buffer_size: int
    connect_timeout: float
    read_timeout: float | None
    write_timeout: float | None

    @classmethod
    def from_env(cls) -> "ExportConfig":
        return cls(
            source=KuboEndpoint.parse(os.environ.get("IPFS_LAPTOP_API_SOCKET", os.path.expanduser("~/.var/run/ipfs-laptop-api.sock"))),
            destination=KuboEndpoint.parse(os.environ.get("RHEA_IPFS_WASABI_SOCKET", os.path.expanduser("~/.var/run/rhea-ipfs-wasabi.sock"))),
            retry_delay=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_RETRY_DELAY"), default=DEFAULT_RETRY_DELAY, maximum=86400.0),
            lock_path=Path(os.environ.get("IPFS_DAG_EXPORT_LOCK", DEFAULT_LOCK)).expanduser(),
            terminate_timeout=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_EXPORT_TERMINATE_TIMEOUT"), default=DEFAULT_TERMINATE_TIMEOUT, maximum=MAX_TERMINATE_TIMEOUT),
            lock_poll_interval=parse_positive_finite_float(os.environ.get("IPFS_DAG_EXPORT_LOCK_POLL_INTERVAL"), default=DEFAULT_LOCK_POLL_INTERVAL, maximum=10.0),
            hook=os.environ.get("IPFS_DAG_EXPORT_SYNC_HOOK"),
            chunk_size=_parse_positive_int(os.environ.get("IPFS_DAG_CHUNK_SIZE"), default=DEFAULT_CHUNK_SIZE),
            buffer_size=_parse_positive_int(os.environ.get("IPFS_DAG_BUFFER_SIZE"), default=DEFAULT_BUFFER_SIZE),
            connect_timeout=parse_positive_finite_float(os.environ.get("IPFS_DAG_HTTP_CONNECT_TIMEOUT"), default=DEFAULT_CONNECT_TIMEOUT, maximum=3600.0),
            read_timeout=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_HTTP_READ_TIMEOUT"), default=DEFAULT_READ_TIMEOUT, maximum=86400.0),
            write_timeout=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_HTTP_WRITE_TIMEOUT"), default=DEFAULT_WRITE_TIMEOUT, maximum=86400.0),
        )

    @property
    def max_chunks(self) -> int:
        return max(1, self.buffer_size // self.chunk_size)


@dataclass(frozen=True)
class DataChunk:
    data: bytes


@dataclass(frozen=True)
class ProducerFailed:
    error: BaseException


@dataclass
class TransferResult:
    cid: str
    bytes_exported: int = 0
    bytes_uploaded: int = 0
    maximum_queue_depth: int = 0
    started_at: float = 0.0
    finished_at: float = 0.0


class ShutdownRequested(BaseException):
    def __init__(self, signum: int):
        super().__init__(signum); self.signum = signum


class ExporterError(RuntimeError):
    pass


class TransferCleanupFailed(ExporterError):
    """The current transfer could not be safely stopped."""


class ExternalProcessCleanupFailed(RuntimeError):
    pass


def process_group_exists(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

    proc = Path("/proc")
    if proc.is_dir():
        saw_group_member = False
        for stat_file in proc.glob("[0-9]*/stat"):
            try:
                text = stat_file.read_text(encoding="utf-8", errors="replace")
                close = text.rfind(")")
                fields = text[close + 2 :].split()
                state = fields[0]
                process_pgid = int(fields[2])
            except (OSError, ValueError, IndexError):
                continue
            if process_pgid == pgid:
                saw_group_member = True
                if state != "Z":
                    return True
        if saw_group_member:
            return False
    return True


def terminate_external_process(
    process: subprocess.Popen[object],
    *,
    grace: float,
    kill_wait: float = 2.0,
) -> None:
    """Terminate, verify, and reap a subprocess group created with start_new_session=True."""
    pgid = process.pid
    term_sent = False
    kill_sent = False

    try:
        os.killpg(pgid, signal.SIGTERM)
        term_sent = True
    except ProcessLookupError:
        pass

    term_deadline = time.monotonic() + max(0.0, grace)
    while process_group_exists(pgid) and time.monotonic() < term_deadline:
        process.poll()
        time.sleep(0.05)

    if process_group_exists(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
            kill_sent = True
        except ProcessLookupError:
            pass

        kill_deadline = time.monotonic() + max(0.1, kill_wait)
        while process_group_exists(pgid) and time.monotonic() < kill_deadline:
            process.poll()
            time.sleep(0.05)

    try:
        process.wait(timeout=max(0.1, kill_wait))
    except subprocess.TimeoutExpired as exc:
        raise ExternalProcessCleanupFailed(
            f"direct process {process.pid} in process group {pgid} could not be reaped; "
            f"term_sent={term_sent} kill_sent={kill_sent} grace={grace:g} kill_wait={kill_wait:g}"
        ) from exc

    if process_group_exists(pgid):
        raise ExternalProcessCleanupFailed(
            f"process group {pgid} for direct process {process.pid} still exists after SIGKILL; "
            f"term_sent={term_sent} kill_sent={kill_sent} grace={grace:g} kill_wait={kill_wait:g}"
        )


_terminate_process_group = terminate_external_process
_kill_process_group = terminate_external_process

class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, unix_socket: Path, timeout: float | None):
        super().__init__("localhost", timeout=timeout)
        self.unix_socket = str(unix_socket)
    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if self.timeout is not None:
            self.sock.settimeout(self.timeout)
        self.sock.connect(self.unix_socket)


def _connection(endpoint: KuboEndpoint, timeout: float | None) -> http.client.HTTPConnection:
    if endpoint.unix_socket:
        return UnixHTTPConnection(endpoint.unix_socket, timeout)
    p = urllib.parse.urlparse(endpoint.base_url)
    cls = http.client.HTTPSConnection if p.scheme == "https" else http.client.HTTPConnection
    return cls(p.hostname or "localhost", p.port, timeout=timeout)


def _path(endpoint: KuboEndpoint, api_path: str, params: dict[str, str]) -> str:
    base_path = urllib.parse.urlparse(endpoint.base_url).path.rstrip("/")
    return f"{base_path}{api_path}?{urllib.parse.urlencode(params)}"


def _read_error_body(resp: http.client.HTTPResponse) -> str:
    data = resp.read(ERROR_SNIPPET_LIMIT + 1)
    if len(data) > ERROR_SNIPPET_LIMIT:
        data = data[:ERROR_SNIPPET_LIMIT] + b"..."
    text = data.decode("utf-8", "replace")
    try:
        obj = json.loads(text)
        return str(obj.get("Message") or obj.get("message") or text)
    except Exception:
        return text


class ActiveCloserRegistry:
    def __init__(self):
        self._closers: list[object] = []
        self._lock = threading.Lock()
    def add(self, obj: object) -> None:
        with self._lock: self._closers.append(obj)
    def remove(self, obj: object) -> None:
        with self._lock:
            with contextlib.suppress(ValueError): self._closers.remove(obj)
    def close_active(self) -> None:
        with self._lock: active = list(self._closers)
        for obj in active:
            try: obj.close()  # type: ignore[attr-defined]
            except Exception: pass
    def count(self) -> int:
        with self._lock: return len(self._closers)


class TransferAttempt:
    def __init__(self, global_shutdown: "ShutdownController"):
        self.global_shutdown = global_shutdown
        self.cancel_event = threading.Event()
        self._closers = ActiveCloserRegistry()
    def cancelled(self) -> bool:
        return self.cancel_event.is_set() or self.global_shutdown.event.is_set()
    def cancel(self) -> None:
        self.cancel_event.set(); self.close_active()
    def add_closer(self, obj: object) -> None: self._closers.add(obj)
    def remove_closer(self, obj: object) -> None: self._closers.remove(obj)
    @contextlib.contextmanager
    def register_closer(self, obj: object):
        self.add_closer(obj)
        try: yield obj
        finally: self.remove_closer(obj)
    def close_active(self) -> None: self._closers.close_active()
    def closer_count(self) -> int: return self._closers.count()


def transfer_should_stop(attempt: TransferAttempt) -> bool:
    return attempt.cancelled()


class ShutdownController:
    def __init__(self):
        self.event = threading.Event(); self.signum: int | None = None; self._closers: list[object] = []
        self._closers_lock = threading.Lock(); self._old: dict[int, object] = {}
    def __enter__(self):
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGINT, signal.SIGTERM):
                self._old[sig] = signal.getsignal(sig); signal.signal(sig, self._handler)
        return self
    def __exit__(self, exc_type, exc, tb):
        for sig, old in self._old.items(): signal.signal(sig, old)
    def _handler(self, signum: int, frame: object) -> None:
        self.signum = signum; self.event.set(); raise ShutdownRequested(signum)
    def add_closer(self, obj: object) -> None:
        with self._closers_lock: self._closers.append(obj)
    def remove_closer(self, obj: object) -> None:
        with self._closers_lock:
            with contextlib.suppress(ValueError): self._closers.remove(obj)
    @contextlib.contextmanager
    def register_closer(self, obj: object):
        self.add_closer(obj)
        try: yield obj
        finally: self.remove_closer(obj)
    def close_active(self) -> None:
        with self._closers_lock: active = list(self._closers)
        for obj in active:
            try: obj.close()  # type: ignore[attr-defined]
            except Exception: pass
    def wait(self, seconds: float) -> bool: return self.event.wait(seconds)
    def closer_count(self) -> int:
        with self._closers_lock: return len(self._closers)


def _queue_put(q: queue.Queue[object], item: object, attempt: TransferAttempt) -> None:
    while not transfer_should_stop(attempt):
        try: q.put(item, timeout=0.1); return
        except queue.Full: continue
    raise ShutdownRequested(attempt.global_shutdown.signum or signal.SIGTERM)


def _producer(cid: str, config: ExportConfig, attempt: TransferAttempt, q: queue.Queue[object], result: TransferResult) -> None:
    conn = None; resp = None
    try:
        conn = _connection(config.source, config.connect_timeout); attempt.add_closer(conn)
        path = _path(config.source, "/api/v0/dag/export", {"arg": cid, "progress": "false"})
        conn.connect()
        if conn.sock is not None:
            conn.sock.settimeout(config.read_timeout)
        conn.request("POST", path, body=None, headers={"Connection": "close"})
        resp = conn.getresponse(); attempt.add_closer(resp)
        if resp.status < 200 or resp.status >= 300:
            raise ExporterError(f"source {config.source.display()} HTTP {resp.status}: {_read_error_body(resp)}")
        while not transfer_should_stop(attempt):
            data = resp.read(config.chunk_size)
            if not data: break
            result.bytes_exported += len(data)
            _queue_put(q, DataChunk(data), attempt)
            result.maximum_queue_depth = max(result.maximum_queue_depth, q.qsize())
        _queue_put(q, _EOF, attempt)
        log(f"Source export completed for {cid}: {result.bytes_exported} bytes")
    except BaseException as exc:
        try: _queue_put(q, ProducerFailed(exc), attempt)
        except BaseException: pass
    finally:
        if resp:
            attempt.remove_closer(resp)
            try: resp.close()
            except Exception: pass
        if conn:
            attempt.remove_closer(conn)
            try: conn.close()
            except Exception: pass

def _multipart_chunks(q: queue.Queue[object], boundary: str, attempt: TransferAttempt, result: TransferResult) -> Iterator[bytes]:
    prefix = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"export.car\"\r\nContent-Type: application/vnd.ipld.car\r\n\r\n").encode()
    suffix = f"\r\n--{boundary}--\r\n".encode()
    yield prefix
    while not transfer_should_stop(attempt):
        try: item = q.get(timeout=0.1)
        except queue.Empty: continue
        if isinstance(item, DataChunk):
            result.bytes_uploaded += len(item.data); yield item.data
        elif isinstance(item, ProducerFailed):
            raise item.error
        elif item is _EOF:
            yield suffix; return
    raise ShutdownRequested(attempt.global_shutdown.signum or signal.SIGTERM)


def _request_streaming_multipart(conn: http.client.HTTPConnection, path: str, chunks: Iterator[bytes], boundary: str, write_timeout: float | None, read_timeout: float | None) -> http.client.HTTPResponse:
    headers = {
        "Connection": "close",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }
    # Establish explicitly with the connection timeout configured on the connection.
    # http.client.request() will not reconnect as long as self.sock remains set.
    conn.connect()
    if conn.sock is not None:
        conn.sock.settimeout(write_timeout)
    conn.request("POST", path, body=chunks, headers=headers, encode_chunked=True)
    if conn.sock is not None:
        conn.sock.settimeout(read_timeout)
    return conn.getresponse()


def transfer_dag(cid: str, config: ExportConfig, shutdown: ShutdownController) -> TransferResult:
    result = TransferResult(cid, started_at=time.monotonic())
    q: queue.Queue[object] = queue.Queue(maxsize=config.max_chunks)
    attempt = TransferAttempt(shutdown)
    producer = threading.Thread(target=_producer, args=(cid, config, attempt, q, result), name=f"dag-export-{cid}", daemon=True)
    producer.start()
    conn = None; resp = None; primary_error: BaseException | None = None
    try:
        boundary = "codex-" + secrets.token_hex(16)
        conn = _connection(config.destination, config.connect_timeout); attempt.add_closer(conn)
        path = _path(config.destination, "/api/v0/dag/import", {"pin-roots": "false", "allow-big-block": "true"})
        resp = _request_streaming_multipart(conn, path, _multipart_chunks(q, boundary, attempt, result), boundary, config.write_timeout, config.read_timeout)
        attempt.add_closer(resp)
        if resp.status < 200 or resp.status >= 300:
            raise ExporterError(f"destination {config.destination.display()} HTTP {resp.status}: {_read_error_body(resp)}")
        _read_error_body(resp)  # bounded success drain (usually tiny JSON)
        log(f"Destination import completed for {cid}: {result.bytes_uploaded} bytes")
    except BaseException as exc:
        primary_error = exc
        attempt.cancel()
        if shutdown.event.is_set():
            shutdown.close_active()
        raise
    finally:
        if resp:
            attempt.remove_closer(resp)
            try: resp.close()
            except Exception: pass
        if conn:
            attempt.remove_closer(conn)
            try: conn.close()
            except Exception: pass
        producer.join(timeout=config.terminate_timeout)
        if producer.is_alive():
            cleanup_error = TransferCleanupFailed(
                f"producer thread for {cid} did not terminate within {config.terminate_timeout:g} seconds"
            )
            if primary_error is not None:
                raise cleanup_error from primary_error
            raise cleanup_error
        result.finished_at = time.monotonic()
    if result.bytes_exported != result.bytes_uploaded:
        raise ExporterError(f"forwarded byte count mismatch for {cid}: exported {result.bytes_exported}, uploaded {result.bytes_uploaded}")
    return result


def acquire_lock_interruptibly(lock_fd: int, config: ExportConfig, shutdown: ShutdownController) -> None:
    log(f"Waiting for export lock {config.lock_path}")
    while not shutdown.event.is_set():
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB); log(f"Acquired export lock {config.lock_path}"); return
        except BlockingIOError:
            shutdown.wait(config.lock_poll_interval)
    raise ShutdownRequested(shutdown.signum or signal.SIGTERM)


def process_cid(cid: str, config: ExportConfig | None = None) -> int:
    config = config or ExportConfig.from_env()
    config.lock_path.parent.mkdir(parents=True, exist_ok=True)
    with ShutdownController() as shutdown:
        try:
            with open(config.lock_path, "a+b", buffering=0) as lock_file:
                os.set_inheritable(lock_file.fileno(), False)
                acquire_lock_interruptibly(lock_file.fileno(), config, shutdown)
                attempt = 0
                while not shutdown.event.is_set():
                    attempt += 1
                    log(f"Attempt {attempt}: transferring {cid} from {config.source.display()} to {config.destination.display()} with chunks={config.chunk_size} buffer={config.buffer_size}")
                    try:
                        if config.hook:
                            proc = subprocess.Popen([config.hook, cid], start_new_session=True, close_fds=True)
                            try: rc = proc.wait()
                            except BaseException:
                                terminate_external_process(proc, grace=config.terminate_timeout)
                                raise
                            if rc != 0: raise ExporterError(f"hook exited with status {rc}")
                        else:
                            res = transfer_dag(cid, config, shutdown)
                            log(f"Done {cid}: exported/uploaded {res.bytes_exported} bytes; max queue depth {res.maximum_queue_depth}")
                        return 0
                    except ShutdownRequested as exc:
                        return 128 + exc.signum
                    except TransferCleanupFailed as exc:
                        log(f"Fatal transfer cleanup failure for {cid}: {exc}")
                        return 1
                    except BaseException as exc:
                        if shutdown.event.is_set(): return 128 + (shutdown.signum or signal.SIGTERM)
                        log(f"Exporter failed for {cid} on attempt {attempt}: {exc}")
                        log(f"Retrying {cid} in {config.retry_delay:g} seconds")
                        if shutdown.wait(config.retry_delay): break
                return 128 + (shutdown.signum or signal.SIGTERM)
        except ShutdownRequested as exc:
            return 128 + exc.signum


def _ensure_fifo(path: Path) -> None:
    if path.exists() and not stat.S_ISFIFO(path.stat().st_mode):
        raise ExporterError(f"{path} exists but is not a FIFO")
    if not path.exists(): os.mkfifo(path)


def run_fifo_worker(queue_path: Path = Path(QUEUE_PATH), config: ExportConfig | None = None) -> int:
    config = config or ExportConfig.from_env(); _ensure_fifo(queue_path)
    with ShutdownController() as shutdown:
        log(f"Waiting for CIDs on {queue_path}")
        fd = os.open(queue_path, os.O_RDWR | os.O_NONBLOCK)  # keep FIFO open to avoid idle EOF busy loops
        try:
            buf = b""
            while not shutdown.event.is_set():
                import select
                r, _, _ = select.select([fd], [], [], config.lock_poll_interval)
                if not r: continue
                data = os.read(fd, 4096)
                if not data:
                    continue
                buf += data
                while b"\n" in buf and not shutdown.event.is_set():
                    raw, buf = buf.split(b"\n", 1); cid = raw.decode("utf-8", "replace").strip()
                    if not cid: continue
                    override = os.environ.get("RHEA_WASABI_PEBBLE_EXPORT_LAPTOP_DAG_SYNC")
                    if override:
                        import subprocess
                        while not shutdown.event.is_set():
                            proc = subprocess.Popen([override, cid], start_new_session=True, close_fds=True)
                            try:
                                rc = proc.wait()
                            except ShutdownRequested as exc:
                                terminate_external_process(proc, grace=config.terminate_timeout)
                                return 128 + exc.signum
                            except BaseException:
                                terminate_external_process(proc, grace=config.terminate_timeout)
                                raise
                            if rc == 0: break
                            log(f"Exporter failed for {cid} with status {rc}")
                            log(f"Retrying {cid} in {config.retry_delay:g} seconds")
                            if shutdown.wait(config.retry_delay): return 128 + (shutdown.signum or signal.SIGTERM)
                    else:
                        rc = process_cid(cid, config)
                        if rc in (130, 143): return rc
        except ShutdownRequested as exc:
            return 128 + exc.signum
        finally:
            try: os.close(fd)
            except OSError: pass
    return 128 + (shutdown.signum or signal.SIGTERM)


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if len(argv) == 1 and argv[0] not in {"-h", "--help", "export", "fifo-worker"}:
        return process_cid(argv[0])
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    ex = sub.add_parser("export"); ex.add_argument("cid")
    fw = sub.add_parser("fifo-worker"); fw.add_argument("--queue", default=QUEUE_PATH)
    ns = p.parse_args(argv)
    try:
        return run_fifo_worker(Path(ns.queue)) if ns.cmd == "fifo-worker" else process_cid(ns.cid)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr); return 1

if __name__ == "__main__":
    raise SystemExit(main())
