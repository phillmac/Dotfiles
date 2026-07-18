"""Small, dependency-free Python client for Kubo's `/api/v0` RPC API.

The Kubo CLI talks to a running daemon through the same HTTP RPC endpoints
implemented by github.com/ipfs/kubo.  This module focuses on `ipfs add` and
`ipfs pin add`, preserving streamed progress/status events separately so callers
can inspect them programmatically instead of scraping CLI stdout/stderr.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import http.client
import io
import json
import mimetypes
import os
from pathlib import Path
import socket
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, BinaryIO, Iterable, Iterator


@dataclass(frozen=True)
class KuboError:
    """Structured error returned by Kubo or raised by the transport."""

    message: str
    code: int | None = None
    type: str | None = None
    raw: Any = None


@dataclass(frozen=True)
class AddProgress:
    """An `ipfs add --progress` event that has bytes but no final hash yet."""

    name: str
    bytes: int
    raw: dict[str, Any]


@dataclass(frozen=True)
class AddEntry:
    """A final file/directory listing event emitted by `/api/v0/add`."""

    name: str
    hash: str
    size: str | None = None
    mode: str | None = None
    mtime: int | None = None
    mtime_nsecs: int | None = None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class AddResult:
    """Programmatic split of add progress, file listing, final CID, and errors."""

    progress: list[AddProgress]
    entries: list[AddEntry]
    cid: str | None
    errors: list[KuboError]
    raw_events: list[dict[str, Any]]


@dataclass(frozen=True)
class PinProgress:
    """An `ipfs pin add --progress` event."""

    progress: int
    bytes: int | None = None
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class PinResult:
    """Programmatic split of pin progress, final pins, and errors."""

    progress: list[PinProgress]
    pins: list[str]
    cid: str | None
    errors: list[KuboError]
    raw_events: list[dict[str, Any]]


MultipartField = tuple[str, str, BinaryIO, str, str | None]


class KuboClient:
    """HTTP RPC client compatible with Kubo daemon `/api/v0` endpoints.

    Parameters mirror `ipfs --api`: pass an HTTP base URL such as
    `http://127.0.0.1:5001` or a Kubo multiaddr such as
    `/ip4/127.0.0.1/tcp/5001`.  Unix socket multiaddrs are accepted when the
    host Python supports `http+unix` only through a custom opener; otherwise a
    clear error is returned in result.errors.
    """

    def __init__(self, api: str = "http://127.0.0.1:5001", timeout: float | None = None):
        self.api = self._normalize_api(api).rstrip("/")
        self.timeout = timeout

    def version(self) -> dict[str, Any]:
        """Return `/api/v0/version` JSON for feature/version decisions."""

        body, _ = self._post("/api/v0/version", {})
        return json.loads(body.decode("utf-8")) if body else {}

    def add(self, paths: str | os.PathLike[str] | Iterable[str | os.PathLike[str]], **options: Any) -> AddResult:
        """Add one or more paths and split streamed progress from final entries.

        Useful options include `recursive`, `pin`, `progress`, `wrap_with_directory`,
        `cid_version`, `raw_leaves`, `only_hash`, `chunker`, and Kubo's newer
        fast-provide flags.  Unknown options are passed through after converting
        underscores to hyphens so newer daemons can be used without changing this
        client.  Progress defaults to true to request the same progress events the
        CLI uses internally.
        """

        option_map = {"progress": True}
        option_map.update(options)
        path_list = [paths] if isinstance(paths, (str, os.PathLike)) else list(paths)
        recursive = bool(option_map.get("recursive"))
        fields, opened = self._multipart_paths(
            path_list,
            recursive=recursive,
            dereference_symlinks=bool(option_map.get("dereference_symlinks")),
            hidden=bool(option_map.get("hidden")),
            nocopy=bool(option_map.get("nocopy")),
        )
        has_root_cid = bool(option_map.get("wrap_with_directory")) or len(path_list) == 1
        try:
            return self._parse_add(self._post_stream("/api/v0/add", option_map, fields), has_root_cid=has_root_cid)
        except KuboErrorException as exc:
            return AddResult([], [], None, [exc.error], [])
        finally:
            for handle in opened:
                handle.close()

    def pin_add(self, cids: str | Iterable[str], **options: Any) -> PinResult:
        """Pin one or more CIDs/paths and split progress from final pin status.

        By default this sends `recursive=true` and `progress=true`, matching the
        common CLI usage `ipfs pin add --progress`.  Kubo versions before useful
        pin progress may emit only the final `Pins` event; newer versions may also
        include `Bytes` in progress events.  Both shapes are accepted.
        """

        args = [cids] if isinstance(cids, str) else list(cids)
        option_map = {"recursive": True, "progress": True}
        option_map.update(options)
        try:
            return self._parse_pin(self._post_stream("/api/v0/pin/add", option_map, None, args=args))
        except KuboErrorException as exc:
            return PinResult([], [], None, [exc.error], [])

    def _post_stream(self, path: str, options: dict[str, Any], fields: list[MultipartField] | None, args: list[str] | None = None):
        query = self._query(options, args=args)
        headers = {"Accept": "application/json"}
        data: bytes | Iterable[bytes] = b""
        if fields is not None:
            data, content_type = self._encode_multipart(fields)
            headers["Content-Type"] = content_type
        try:
            with self._open_stream_response(path + query, data, headers) as resp:
                trailers: dict[str, str] = {}
                for line in self._iter_stream_response_lines(resp, trailers):
                    line = line.strip()
                    if not line:
                        continue
                    yield json.loads(line.decode("utf-8"))
                stream_error = self._stream_error_from_trailers(resp, trailers)
                if stream_error is not None:
                    yield {
                        "Message": stream_error.message,
                        "Code": stream_error.code,
                        "Type": stream_error.type,
                    }
        except (urllib.error.URLError, TimeoutError, socket.timeout, OSError, http.client.HTTPException) as err:
            raise KuboErrorException(KuboError(str(err), raw=err)) from err


    def _open_stream_response(self, path_and_query: str, data: bytes | Iterable[bytes], headers: dict[str, str]):
        url = urllib.parse.urlsplit(self.api)
        if url.scheme not in {"http", "https"}:
            raise urllib.error.URLError(f"Unsupported Kubo API scheme for streaming trailers: {url.scheme}")
        host = url.hostname or ""
        port = url.port
        connection_class = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
        connection = connection_class(host, port, timeout=self.timeout)
        target = (url.path.rstrip("/") + path_and_query) or path_and_query
        connection.request("POST", target, body=data, headers=headers, encode_chunked=not isinstance(data, (bytes, bytearray)))
        resp = connection.getresponse()
        resp._kubo_connection = connection
        if resp.status >= 400:
            body = resp.read()
            connection.close()
            raise KuboErrorException(self._error_from_status(resp.status, resp.reason, body))
        return resp

    @staticmethod
    def _iter_stream_response_lines(resp: http.client.HTTPResponse, trailers: dict[str, str]) -> Iterator[bytes]:
        if resp.getheader("Transfer-Encoding", "").lower() != "chunked":
            while True:
                line = resp.readline()
                if not line:
                    break
                yield line
            return

        pending = b""
        while True:
            size_line = resp.fp.readline()
            if not size_line:
                break
            size = int(size_line.split(b";", 1)[0].strip(), 16)
            if size == 0:
                if pending:
                    yield pending
                    pending = b""
                while True:
                    trailer_line = resp.fp.readline()
                    if trailer_line in {b"\r\n", b"\n", b""}:
                        return
                    name, _, value = trailer_line.decode("iso-8859-1").partition(":")
                    if name:
                        trailers[name.strip().lower()] = value.strip()
                return
            chunk = resp.fp.read(size)
            resp.fp.read(2)
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                yield line + b"\n"
        if pending:
            yield pending

    def _post(self, path: str, options: dict[str, Any]) -> tuple[bytes, Any]:
        req = urllib.request.Request(self.api + path + self._query(options), data=b"", method="POST")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return resp.read(), resp

    @staticmethod
    def _parse_add(events: Iterable[dict[str, Any]], has_root_cid: bool = True) -> AddResult:
        progress: list[AddProgress] = []
        entries: list[AddEntry] = []
        errors: list[KuboError] = []
        raw_events: list[dict[str, Any]] = []
        for event in events:
            raw_events.append(event)
            if "Message" in event and "Code" in event:
                errors.append(KuboError(event.get("Message", "Kubo error"), event.get("Code"), event.get("Type"), event))
            elif event.get("Hash"):
                entries.append(AddEntry(event.get("Name", ""), event["Hash"], event.get("Size"), event.get("Mode"), event.get("Mtime"), event.get("MtimeNsecs"), event))
            elif "Bytes" in event:
                progress.append(AddProgress(event.get("Name", ""), int(event.get("Bytes") or 0), event))
        cid = entries[-1].hash if has_root_cid and entries else None
        return AddResult(progress, entries, cid, errors, raw_events)

    @staticmethod
    def _parse_pin(events: Iterable[dict[str, Any]]) -> PinResult:
        progress: list[PinProgress] = []
        pins: list[str] = []
        errors: list[KuboError] = []
        raw_events: list[dict[str, Any]] = []
        for event in events:
            raw_events.append(event)
            if "Message" in event and "Code" in event:
                errors.append(KuboError(event.get("Message", "Kubo error"), event.get("Code"), event.get("Type"), event))
            elif event.get("Pins") is not None:
                pins.extend(str(pin) for pin in event.get("Pins") or [])
            elif "Progress" in event:
                bytes_value = event.get("Bytes")
                progress.append(PinProgress(int(event.get("Progress") or 0), int(bytes_value) if bytes_value is not None else None, event))
        return PinResult(progress, pins, pins[-1] if pins else None, errors, raw_events)

    @staticmethod
    def _query(options: dict[str, Any], args: list[str] | None = None) -> str:
        pairs: list[tuple[str, str]] = []
        for arg in args or []:
            pairs.append(("arg", arg))
        for key, value in options.items():
            if value is None:
                continue
            name = key.replace("_", "-")
            if isinstance(value, bool):
                value = "true" if value else "false"
            pairs.append((name, str(value)))
        return "?" + urllib.parse.urlencode(pairs) if pairs else ""

    @staticmethod
    def _normalize_api(api: str) -> str:
        if api.startswith("/"):
            parts = api.strip("/").split("/")
            if parts and parts[0] == "unix":
                raise ValueError("Unix socket Kubo APIs need a custom urllib opener; pass an HTTP API URL instead")
            if len(parts) >= 4 and parts[0] in {"ip4", "ip6", "dns", "dns4", "dns6"} and parts[2] == "tcp":
                host = parts[1]
                port = parts[3]
                scheme = "https" if "https" in parts[4:] else "http"
                if "http" in parts[4:] and "https" not in parts[4:]:
                    scheme = "http"
                if ":" in host and not host.startswith("["):
                    host = f"[{host}]"
                return f"{scheme}://{host}:{port}"
        if "://" not in api:
            return "http://" + api
        return api

    @staticmethod
    def _multipart_paths(
        path_list: Iterable[str | os.PathLike[str]],
        recursive: bool = True,
        dereference_symlinks: bool = False,
        hidden: bool = False,
        nocopy: bool = False,
    ):
        fields: list[MultipartField] = []
        opened: list[BinaryIO] = []
        for item in path_list:
            root = Path(item)
            if root.is_symlink() and not dereference_symlinks:
                fields.append(("file", root.name, io.BytesIO(os.fsencode(os.readlink(root))), "application/symlink", None))
                continue
            if root.is_dir():
                if not recursive:
                    raise ValueError(f"Cannot add directory without recursive=True: {root}")
                descendants = KuboClient._directory_descendants(root, dereference_symlinks, hidden)
                files = [child for child in descendants if child.is_file() and (dereference_symlinks or not child.is_symlink())]
                for child in files:
                    rel = str(Path(root.name) / child.relative_to(root))
                    handle = _LazyFile(child)
                    fields.append(("file", rel, handle, mimetypes.guess_type(child.name)[0] or "application/octet-stream", str(child.absolute()) if nocopy else None))
                for child in descendants:
                    if child.is_symlink() and not dereference_symlinks:
                        rel = str(Path(root.name) / child.relative_to(root))
                        fields.append(("file", rel, io.BytesIO(os.fsencode(os.readlink(child))), "application/symlink", None))
                for child in descendants:
                    if child.is_dir() and (dereference_symlinks or not child.is_symlink()) and not any(file.is_relative_to(child) for file in files):
                        rel = str(Path(root.name) / child.relative_to(root))
                        fields.append(("file", rel, io.BytesIO(), "application/x-directory", None))
                if not files and not descendants:
                    fields.append(("file", root.name, io.BytesIO(), "application/x-directory", None))
            else:
                handle = _LazyFile(root)
                fields.append(("file", root.name, handle, mimetypes.guess_type(root.name)[0] or "application/octet-stream", str(root.absolute()) if nocopy else None))
        return fields, opened

    @staticmethod
    def _directory_descendants(root: Path, dereference_symlinks: bool, hidden: bool) -> list[Path]:
        if not dereference_symlinks:
            return [
                child
                for child in sorted(root.rglob("*"))
                if hidden or not KuboClient._is_hidden_descendant(root, child)
            ]

        descendants: list[Path] = []
        root_identity = KuboClient._directory_identity(root)
        seen_directories = {root_identity} if root_identity is not None else set()
        for current, dirnames, filenames in os.walk(root, followlinks=True):
            current_path = Path(current)
            dirnames.sort()
            filenames.sort()
            pruned_dirnames = []
            for dirname in dirnames:
                child = current_path / dirname
                if not hidden and KuboClient._is_hidden_descendant(root, child):
                    continue
                identity = KuboClient._directory_identity(child)
                if identity is not None and identity in seen_directories:
                    continue
                if identity is not None:
                    seen_directories.add(identity)
                pruned_dirnames.append(dirname)
            dirnames[:] = pruned_dirnames
            if not hidden:
                filenames = [
                    filename
                    for filename in filenames
                    if not KuboClient._is_hidden_descendant(root, current_path / filename)
                ]
            descendants.extend(current_path / dirname for dirname in dirnames)
            descendants.extend(current_path / filename for filename in filenames)
        return descendants

    @staticmethod
    def _directory_identity(path: Path) -> tuple[int, int] | None:
        try:
            stat = path.stat()
        except OSError:
            return None
        return (stat.st_dev, stat.st_ino)

    @staticmethod
    def _is_hidden_descendant(root: Path, path: Path) -> bool:
        return any(part.startswith(".") for part in path.relative_to(root).parts)

    @staticmethod
    def _encode_multipart(fields: list[MultipartField]) -> tuple[Iterable[bytes], str]:
        boundary = "----kubo-python-" + uuid.uuid4().hex
        return _MultipartStream(fields, boundary), f"multipart/form-data; boundary={boundary}"

    @staticmethod
    def _multipart_filename(filename: str) -> str:
        return urllib.parse.quote(filename, safe="-._~")

    @staticmethod
    def _stream_error_from_trailers(resp: Any, trailers: dict[str, str] | None = None) -> KuboError | None:
        message = (trailers or {}).get("x-stream-error")
        for source_name in ("trailers", "headers") if not message else ():
            source = getattr(resp, source_name, None)
            if source is not None and hasattr(source, "get"):
                message = source.get("X-Stream-Error") or source.get("x-stream-error")
                if message:
                    break
        if not message and hasattr(resp, "getheader"):
            message = resp.getheader("X-Stream-Error")
        if not message:
            return None
        code = getattr(resp, "status", None) or getattr(resp, "code", None)
        return KuboError(str(message), code, "stream", {"X-Stream-Error": str(message)})

    @staticmethod
    def _error_from_status(status: int, reason: str, body: bytes) -> KuboError:
        try:
            parsed = json.loads(body.decode("utf-8"))
            return KuboError(parsed.get("Message", reason), parsed.get("Code", status), parsed.get("Type"), parsed)
        except Exception:
            return KuboError(body.decode("utf-8", "replace") or reason, status, raw=body)

    @staticmethod
    def _error_from_http(err: urllib.error.HTTPError) -> KuboError:
        return KuboClient._error_from_status(err.code, err.reason, err.read())


class _MultipartStream:
    """Iterable multipart body that reads file handles incrementally."""

    chunk_size = 64 * 1024

    def __init__(self, fields: list[MultipartField], boundary: str):
        self.fields = fields
        self.boundary = boundary

    def __iter__(self) -> Iterator[bytes]:
        for field, filename, handle, content_type, abspath in self.fields:
            yield f"--{self.boundary}\r\n".encode()
            encoded_filename = KuboClient._multipart_filename(filename)
            yield f'Content-Disposition: form-data; name="{field}"; filename="{encoded_filename}"\r\n'.encode()
            yield f"Content-Type: {content_type}\r\n".encode()
            if abspath is not None:
                yield f"Abspath: {abspath}\r\n".encode()
            yield b"\r\n"
            try:
                while True:
                    chunk = handle.read(self.chunk_size)
                    if not chunk:
                        break
                    yield chunk
            finally:
                if hasattr(handle, "close"):
                    handle.close()
            yield b"\r\n"
        yield f"--{self.boundary}--\r\n".encode()


class _LazyFile:
    """Binary file-like wrapper that opens a path only while it is being read."""

    def __init__(self, path: Path):
        self.path = path
        self._handle: BinaryIO | None = None

    def read(self, size: int = -1) -> bytes:
        if size is None or size < 0:
            with self.path.open("rb") as handle:
                return handle.read()

        if self._handle is None:
            self._handle = self.path.open("rb")
        chunk = self._handle.read(size)
        if not chunk:
            self.close()
        return chunk

    def close(self) -> None:
        if self._handle is not None:
            self._handle.close()
            self._handle = None


class KuboErrorException(Exception):
    def __init__(self, error: KuboError):
        super().__init__(error.message)
        self.error = error
