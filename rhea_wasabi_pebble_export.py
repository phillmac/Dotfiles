#!/usr/bin/env python3
"""Direct Kubo RPC DAG exporter and FIFO worker.

Streams an opaque CAR from a source Kubo /api/v0/dag/export response to a
bounded in-memory queue, then into a destination Kubo /api/v0/dag/import
streaming multipart/form-data request.  No Docker, ipfs CLI, mbuffer, CAR files,
or complete-CAR buffering are used by the built-in exporter.
"""
from __future__ import annotations

import argparse, fcntl, http.client, json, math, os, queue, secrets, signal, socket, stat, sys, threading, time, urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

DEFAULT_LOCK = os.path.expanduser("~/.var/run/rhea-wasabi-pebble-export-laptop-dag.lock")
DEFAULT_RETRY_DELAY = 300.0
DEFAULT_TERMINATE_TIMEOUT = 5.0
MAX_TERMINATE_TIMEOUT = 60.0
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
            retry_delay=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_RETRY_DELAY"), default=DEFAULT_RETRY_DELAY, maximum=86400.0) or 0.0,
            lock_path=Path(os.environ.get("IPFS_DAG_EXPORT_LOCK", DEFAULT_LOCK)).expanduser(),
            terminate_timeout=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_EXPORT_TERMINATE_TIMEOUT"), default=DEFAULT_TERMINATE_TIMEOUT, maximum=MAX_TERMINATE_TIMEOUT) or DEFAULT_TERMINATE_TIMEOUT,
            lock_poll_interval=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_EXPORT_LOCK_POLL_INTERVAL"), default=DEFAULT_LOCK_POLL_INTERVAL, maximum=10.0) or DEFAULT_LOCK_POLL_INTERVAL,
            hook=os.environ.get("IPFS_DAG_EXPORT_SYNC_HOOK"),
            chunk_size=_parse_positive_int(os.environ.get("IPFS_DAG_CHUNK_SIZE"), default=DEFAULT_CHUNK_SIZE),
            buffer_size=_parse_positive_int(os.environ.get("IPFS_DAG_BUFFER_SIZE"), default=DEFAULT_BUFFER_SIZE),
            connect_timeout=parse_nonnegative_finite_float(os.environ.get("IPFS_DAG_HTTP_CONNECT_TIMEOUT"), default=DEFAULT_CONNECT_TIMEOUT, maximum=3600.0) or DEFAULT_CONNECT_TIMEOUT,
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


class ShutdownController:
    def __init__(self):
        self.event = threading.Event(); self.signum: int | None = None; self._closers: list[object] = []
        self._old: dict[int, object] = {}
    def __enter__(self):
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGINT, signal.SIGTERM):
                self._old[sig] = signal.getsignal(sig); signal.signal(sig, self._handler)
        return self
    def __exit__(self, exc_type, exc, tb):
        for sig, old in self._old.items(): signal.signal(sig, old)
    def _handler(self, signum: int, frame: object) -> None:
        self.signum = signum; self.event.set(); self.close_active(); raise ShutdownRequested(signum)
    def add_closer(self, obj: object) -> None: self._closers.append(obj)
    def close_active(self) -> None:
        for obj in list(self._closers):
            try: obj.close()  # type: ignore[attr-defined]
            except Exception: pass
    def wait(self, seconds: float) -> bool: return self.event.wait(seconds)


def _queue_put(q: queue.Queue[object], item: object, shutdown: ShutdownController) -> None:
    while not shutdown.event.is_set():
        try: q.put(item, timeout=0.1); return
        except queue.Full: continue
    raise ShutdownRequested(shutdown.signum or signal.SIGTERM)


def _producer(cid: str, config: ExportConfig, shutdown: ShutdownController, q: queue.Queue[object], result: TransferResult) -> None:
    conn = None
    try:
        conn = _connection(config.source, config.connect_timeout); shutdown.add_closer(conn)
        path = _path(config.source, "/api/v0/dag/export", {"arg": cid, "progress": "false"})
        conn.request("POST", path, body=None, headers={"Connection": "close"})
        resp = conn.getresponse(); shutdown.add_closer(resp)
        if conn.sock is not None:
            conn.sock.settimeout(config.read_timeout)
        if resp.status < 200 or resp.status >= 300:
            raise ExporterError(f"source {config.source.display()} HTTP {resp.status}: {_read_error_body(resp)}")
        while not shutdown.event.is_set():
            data = resp.read(config.chunk_size)
            if not data: break
            result.bytes_exported += len(data)
            _queue_put(q, DataChunk(data), shutdown)
            result.maximum_queue_depth = max(result.maximum_queue_depth, q.qsize())
        _queue_put(q, _EOF, shutdown)
        log(f"Source export completed for {cid}: {result.bytes_exported} bytes")
    except BaseException as exc:
        try: _queue_put(q, ProducerFailed(exc), shutdown)
        except BaseException: pass
    finally:
        try:
            if conn: conn.close()
        except Exception: pass


def _multipart_chunks(q: queue.Queue[object], boundary: str, shutdown: ShutdownController, result: TransferResult) -> Iterator[bytes]:
    prefix = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"export.car\"\r\nContent-Type: application/vnd.ipld.car\r\n\r\n").encode()
    suffix = f"\r\n--{boundary}--\r\n".encode()
    yield prefix
    while not shutdown.event.is_set():
        try: item = q.get(timeout=0.1)
        except queue.Empty: continue
        if isinstance(item, DataChunk):
            result.bytes_uploaded += len(item.data); yield item.data
        elif isinstance(item, ProducerFailed):
            raise item.error
        elif item is _EOF:
            yield suffix; return
    raise ShutdownRequested(shutdown.signum or signal.SIGTERM)


def _request_streaming_multipart(conn: http.client.HTTPConnection, path: str, chunks: Iterator[bytes], boundary: str, write_timeout: float | None, read_timeout: float | None) -> http.client.HTTPResponse:
    headers = {
        "Connection": "close",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }
    conn.request("POST", path, body=chunks, headers=headers, encode_chunked=True)
    if conn.sock and read_timeout is not None:
        conn.sock.settimeout(read_timeout)
    return conn.getresponse()


def transfer_dag(cid: str, config: ExportConfig, shutdown: ShutdownController) -> TransferResult:
    result = TransferResult(cid, started_at=time.monotonic())
    q: queue.Queue[object] = queue.Queue(maxsize=config.max_chunks)
    producer = threading.Thread(target=_producer, args=(cid, config, shutdown, q, result), name=f"dag-export-{cid}", daemon=True)
    producer.start()
    conn = None
    try:
        boundary = "codex-" + secrets.token_hex(16)
        conn = _connection(config.destination, config.connect_timeout); shutdown.add_closer(conn)
        path = _path(config.destination, "/api/v0/dag/import", {"pin-roots": "false", "allow-big-block": "true"})
        if conn.sock and config.write_timeout is not None:
            conn.sock.settimeout(config.write_timeout)
        resp = _request_streaming_multipart(conn, path, _multipart_chunks(q, boundary, shutdown, result), boundary, config.write_timeout, config.read_timeout)
        if resp.status < 200 or resp.status >= 300:
            raise ExporterError(f"destination {config.destination.display()} HTTP {resp.status}: {_read_error_body(resp)}")
        _read_error_body(resp)  # bounded success drain (usually tiny JSON)
        log(f"Destination import completed for {cid}: {result.bytes_uploaded} bytes")
    except BaseException:
        shutdown.event.set(); shutdown.close_active(); raise
    finally:
        if conn:
            try: conn.close()
            except Exception: pass
        producer.join(timeout=config.terminate_timeout)
        if producer.is_alive():
            raise ExporterError("producer thread did not terminate")
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
                            import subprocess
                            proc = subprocess.Popen([config.hook, cid], start_new_session=True, close_fds=True)
                            try: rc = proc.wait()
                            except ShutdownRequested: proc.terminate(); raise
                            if rc != 0: raise ExporterError(f"hook exited with status {rc}")
                        else:
                            res = transfer_dag(cid, config, shutdown)
                            log(f"Done {cid}: exported/uploaded {res.bytes_exported} bytes; max queue depth {res.maximum_queue_depth}")
                        return 0
                    except ShutdownRequested as exc:
                        return 128 + exc.signum
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
        fd = os.open(queue_path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            buf = b""
            while not shutdown.event.is_set():
                import select
                r, _, _ = select.select([fd], [], [], config.lock_poll_interval)
                if not r: continue
                data = os.read(fd, 4096)
                if not data:
                    os.close(fd); fd = os.open(queue_path, os.O_RDONLY | os.O_NONBLOCK); continue
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
                                try: os.killpg(proc.pid, signal.SIGTERM)
                                except ProcessLookupError: pass
                                return 128 + exc.signum
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
