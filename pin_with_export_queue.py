#!/usr/bin/env python3
"""Pin a CID, exporting missing blocks through a queue socket as needed."""
from __future__ import annotations

import argparse
import re
import socket
import sys
import time
from pathlib import Path

from kubo_api_client import KuboClient, KuboError, PinResult

_MISSING_BLOCK_RE = re.compile(r"(?:could not find|not found locally).*?((?:Qm[1-9A-HJ-NP-Za-km-z]+)|(?:ba[a-z2-7]+))", re.IGNORECASE)


def missing_block_cid(result: PinResult) -> str | None:
    """Return the first missing block CID reported by a failed pin attempt."""

    for error in result.errors:
        cid = missing_block_cid_from_error(error)
        if cid:
            return cid
    return None


def missing_block_cid_from_error(error: KuboError) -> str | None:
    """Extract the missing block CID from Kubo's offline pin error text."""

    match = _MISSING_BLOCK_RE.search(error.message)
    return match.group(1) if match else None


def enqueue_export(socket_path: str | Path, cid: str, timeout: float | None = None) -> bytes:
    """Send a missing block CID to the export queue Unix socket and wait for EOF."""

    payload = f"{cid}\n".encode("utf-8")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(str(socket_path))
        sock.sendall(payload)
        sock.shutdown(socket.SHUT_WR)
        chunks: list[bytes] = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    return b"".join(chunks)


def pin_with_export_queue(
    cid: str,
    socket_path: str | Path,
    *,
    api: str = "http://127.0.0.1:5001",
    timeout: float | None = None,
    max_attempts: int = 0,
    retry_delay: float = 0.0,
    recursive: bool = True,
    progress: bool = True,
    verbose: bool = False,
) -> PinResult:
    """Retry pinning *cid*, exporting each missing block before the next attempt.

    ``max_attempts=0`` means retry until the pin succeeds or Kubo returns an error
    that does not identify a missing block CID.
    """

    client = KuboClient(api, timeout=timeout)
    attempts = 0
    while True:
        attempts += 1
        result = client.pin_add(cid, recursive=recursive, progress=progress)
        if not result.errors:
            return result

        missing_cid = missing_block_cid(result)
        if not missing_cid:
            return result
        if max_attempts and attempts >= max_attempts:
            return result

        if verbose:
            print(f"pin attempt {attempts} is missing {missing_cid}; enqueueing export", file=sys.stderr)
        enqueue_export(socket_path, missing_cid, timeout=timeout)
        if retry_delay:
            time.sleep(retry_delay)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cid", help="Root CID to pin, for example QmhashA")
    parser.add_argument("socket", help="Unix socket used by the export queue")
    parser.add_argument("--api", default="http://127.0.0.1:5001", help="Kubo RPC API URL or multiaddr")
    parser.add_argument("--timeout", type=float, default=None, help="Timeout in seconds for API and socket operations")
    parser.add_argument("--max-attempts", type=int, default=0, help="Maximum pin attempts; 0 means unlimited")
    parser.add_argument("--retry-delay", type=float, default=0.0, help="Seconds to wait after an export completes")
    parser.add_argument("--no-recursive", action="store_true", help="Pass recursive=false to pin/add")
    parser.add_argument("--no-progress", action="store_true", help="Pass progress=false to pin/add")
    parser.add_argument("-v", "--verbose", action="store_true", help="Log missing blocks to stderr")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    result = pin_with_export_queue(
        args.cid,
        args.socket,
        api=args.api,
        timeout=args.timeout,
        max_attempts=args.max_attempts,
        retry_delay=args.retry_delay,
        recursive=not args.no_recursive,
        progress=not args.no_progress,
        verbose=args.verbose,
    )
    if result.errors:
        for error in result.errors:
            print(f"Error: {error.message}", file=sys.stderr)
        return 1
    for pinned in result.pins:
        print(pinned)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
