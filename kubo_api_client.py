"""Small, dependency-free Python client for Kubo's `/api/v0` RPC API.

The Kubo CLI talks to a running daemon through the same HTTP RPC endpoints
implemented by github.com/ipfs/kubo.  This module focuses on `ipfs add` and
`ipfs pin add`, preserving streamed progress/status events separately so callers
can inspect them programmatically instead of scraping CLI stdout/stderr.
"""
from __future__ import annotations

from dataclasses import dataclass, field
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
        fields, opened = self._multipart_paths(path_list, dereference_symlinks=bool(option_map.get("dereference_symlinks")))
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

    def _post_stream(self, path: str, options: dict[str, Any], fields: list[tuple[str, str, BinaryIO, str]] | None, args: list[str] | None = None):
        query = self._query(options, args=args)
        headers = {"Accept": "application/json"}
        data: bytes | Iterable[bytes] = b""
        if fields is not None:
            data, content_type = self._encode_multipart(fields)
            headers["Content-Type"] = content_type
        req = urllib.request.Request(self.api + path + query, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                for line in resp:
                    line = line.strip()
                    if not line:
                        continue
                    yield json.loads(line.decode("utf-8"))
                stream_error = self._stream_error_from_trailers(resp)
                if stream_error is not None:
                    yield {
                        "Message": stream_error.message,
                        "Code": stream_error.code,
                        "Type": stream_error.type,
                    }
        except urllib.error.HTTPError as err:
            raise KuboErrorException(self._error_from_http(err)) from err
        except (urllib.error.URLError, TimeoutError, socket.timeout, OSError) as err:
            raise KuboErrorException(KuboError(str(err), raw=err)) from err

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
        if api.startswith("/ip4/") or api.startswith("/ip6/"):
            parts = api.strip("/").split("/")
            host = parts[1]
            port = parts[3]
            if ":" in host and not host.startswith("["):
                host = f"[{host}]"
            return f"http://{host}:{port}"
        if api.startswith("/unix/"):
            raise ValueError("Unix socket Kubo APIs need a custom urllib opener; pass an HTTP API URL instead")
        if "://" not in api:
            return "http://" + api
        return api

    @staticmethod
    def _multipart_paths(path_list: Iterable[str | os.PathLike[str]], dereference_symlinks: bool = False):
        fields: list[tuple[str, str, BinaryIO, str]] = []
        opened: list[BinaryIO] = []
        for item in path_list:
            root = Path(item)
            if root.is_symlink() and not dereference_symlinks:
                fields.append(("file", root.name, io.BytesIO(os.fsencode(os.readlink(root))), "application/symlink"))
                continue
            if root.is_dir():
                descendants = sorted(root.rglob("*"))
                files = [child for child in descendants if child.is_file() and (dereference_symlinks or not child.is_symlink())]
                for child in files:
                    rel = str(Path(root.name) / child.relative_to(root))
                    handle = child.open("rb")
                    opened.append(handle)
                    fields.append(("file", rel, handle, mimetypes.guess_type(child.name)[0] or "application/octet-stream"))
                for child in descendants:
                    if child.is_symlink() and not dereference_symlinks:
                        rel = str(Path(root.name) / child.relative_to(root))
                        fields.append(("file", rel, io.BytesIO(os.fsencode(os.readlink(child))), "application/symlink"))
                for child in descendants:
                    if child.is_dir() and not child.is_symlink() and not any(file.is_relative_to(child) for file in files):
                        rel = str(Path(root.name) / child.relative_to(root))
                        fields.append(("file", rel, io.BytesIO(), "application/x-directory"))
                if not files and not descendants:
                    fields.append(("file", root.name, io.BytesIO(), "application/x-directory"))
            else:
                handle = root.open("rb")
                opened.append(handle)
                fields.append(("file", root.name, handle, mimetypes.guess_type(root.name)[0] or "application/octet-stream"))
        return fields, opened

    @staticmethod
    def _encode_multipart(fields: list[tuple[str, str, BinaryIO, str]]) -> tuple[Iterable[bytes], str]:
        boundary = "----kubo-python-" + uuid.uuid4().hex
        return _MultipartStream(fields, boundary), f"multipart/form-data; boundary={boundary}"

    @staticmethod
    def _stream_error_from_trailers(resp: Any) -> KuboError | None:
        message = None
        for source_name in ("trailers", "headers"):
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
    def _error_from_http(err: urllib.error.HTTPError) -> KuboError:
        body = err.read()
        try:
            parsed = json.loads(body.decode("utf-8"))
            return KuboError(parsed.get("Message", err.reason), parsed.get("Code", err.code), parsed.get("Type"), parsed)
        except Exception:
            return KuboError(body.decode("utf-8", "replace") or err.reason, err.code, raw=body)


class _MultipartStream:
    """Iterable multipart body that reads file handles incrementally."""

    chunk_size = 64 * 1024

    def __init__(self, fields: list[tuple[str, str, BinaryIO, str]], boundary: str):
        self.fields = fields
        self.boundary = boundary

    def __iter__(self) -> Iterator[bytes]:
        for field, filename, handle, content_type in self.fields:
            yield f"--{self.boundary}\r\n".encode()
            yield f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'.encode()
            yield f"Content-Type: {content_type}\r\n\r\n".encode()
            while True:
                chunk = handle.read(self.chunk_size)
                if not chunk:
                    break
                yield chunk
            yield b"\r\n"
        yield f"--{self.boundary}--\r\n".encode()


class KuboErrorException(Exception):
    def __init__(self, error: KuboError):
        super().__init__(error.message)
        self.error = error
