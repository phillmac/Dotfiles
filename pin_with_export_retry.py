#!/usr/bin/env python3
"""Pin a CID, synchronously exporting missing child blocks as needed."""
from __future__ import annotations

import argparse
import math
import os
import re
import signal
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

from kubo_api_client import KuboClient, KuboError, PinResult

DEFAULT_EXPORT_COMMAND = str(Path(__file__).resolve().parent / ".bashrc.d" / "carpo.bashrc.d" / "rhea-wasabi-pebble-export-laptop-dag-sync")
from rhea_wasabi_pebble_export import (
    ExternalProcessCleanupFailed,
    ExternalProcessGroupSurvived,
    exporter_cleanup_timeout_from_environment as _shared_exporter_cleanup_timeout_from_environment,
    terminate_external_process,
    wait_and_verify_external_process,
)

_MISSING_BLOCK_RE = re.compile(r"(?:could not find|not found locally).*?((?:Qm[1-9A-HJ-NP-Za-km-z]+)|(?:ba[a-z2-7]+))", re.IGNORECASE)


@dataclass(frozen=True)
class ExportFailure:
    missing_cid: str
    export_command: str
    status: str
    message: str

    def as_error(self) -> KuboError:
        return KuboError(
            f"synchronous export/import failed for missing CID {self.missing_cid} "
            f"using {self.export_command!r}: {self.status}. {self.message}"
        )


class ExportFailed(RuntimeError):
    def __init__(self, failure: ExportFailure):
        super().__init__(failure.as_error().message)
        self.failure = failure


def missing_block_cid(result: PinResult) -> str | None:
    for error in result.errors:
        cid = missing_block_cid_from_error(error)
        if cid:
            return cid
    return None


def missing_block_cid_from_error(error: KuboError) -> str | None:
    match = _MISSING_BLOCK_RE.search(error.message)
    return match.group(1) if match else None


def exporter_cleanup_timeout_from_environment() -> float:
    return _shared_exporter_cleanup_timeout_from_environment()


def _terminate_process_group(
    process: subprocess.Popen[object],
    signum: int = signal.SIGTERM,
    *,
    wait_timeout: float | None = None,
) -> None:
    terminate_external_process(
        process,
        initial_signal=signum,
        grace=exporter_cleanup_timeout_from_environment() if wait_timeout is None else wait_timeout,
    )


_kill_process_group = _terminate_process_group


class _ExporterSignalReceived(BaseException):
    def __init__(self, signum: int):
        super().__init__(signum)
        self.signum = signum


def _structured_start_failure(missing_cid: str, command: str, exc: OSError) -> ExportFailed:
    failure = ExportFailure(
        missing_cid,
        command,
        f"could not start exporter: {exc}",
        "No synchronous export/import was performed.",
    )
    return ExportFailed(failure)


def export_missing_cid(missing_cid: str, export_command: str | Path = DEFAULT_EXPORT_COMMAND, *, timeout: float | None = None) -> None:
    command = str(export_command)
    try:
        process = subprocess.Popen([command, missing_cid], start_new_session=True)
    except OSError as exc:
        raise _structured_start_failure(missing_cid, command, exc) from exc

    installed_handlers: dict[int, object] = {}

    def handler(signum: int, frame: object) -> None:
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass
        raise _ExporterSignalReceived(signum)

    can_install_handlers = threading.current_thread() is threading.main_thread()
    if can_install_handlers:
        for signum in (signal.SIGINT, signal.SIGTERM):
            installed_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, handler)

    try:
        try:
            returncode = wait_and_verify_external_process(
                process,
                cleanup_grace=exporter_cleanup_timeout_from_environment(),
                context=f"synchronous exporter for missing CID {missing_cid}",
                timeout=timeout,
            )
        except _ExporterSignalReceived as exc:
            cleanup_error = None
            try:
                _terminate_process_group(process, signal.SIGTERM)
            except ExternalProcessCleanupFailed as cleanup_exc:
                cleanup_error = cleanup_exc
            if cleanup_error is not None:
                print(f"outer exporter cleanup for {missing_cid} pid={process.pid} pgid={process.pid} during signal {exc.signum}: process cleanup failed: {cleanup_error}", file=sys.stderr)
            if exc.signum == signal.SIGINT:
                raise KeyboardInterrupt
            raise SystemExit(128 + exc.signum)
        except subprocess.TimeoutExpired as exc:
            cleanup_error = None
            try:
                _terminate_process_group(process, signal.SIGTERM)
            except ExternalProcessCleanupFailed as cleanup_exc:
                cleanup_error = cleanup_exc
            status = f"timeout after {timeout} seconds"
            message = "The synchronous exporter did not finish before the configured timeout."
            if cleanup_error is not None:
                status += "; process-group cleanup failed"
                message += f" Cleanup error: {cleanup_error}"
            raise ExportFailed(ExportFailure(missing_cid, command, status, message)) from exc
        except ExternalProcessGroupSurvived as exc:
            raise ExportFailed(
                ExportFailure(
                    missing_cid,
                    command,
                    "leader exited with surviving descendants",
                    f"The synchronous exporter leader exited with surviving descendants. {exc}",
                )
            ) from exc
        except ExternalProcessCleanupFailed as exc:
            raise ExportFailed(
                ExportFailure(
                    missing_cid,
                    command,
                    "process-group cleanup failed",
                    f"The synchronous exporter process group could not be verified clean. {exc}",
                )
            ) from exc
        except BaseException as exc:
            try:
                _terminate_process_group(process, signal.SIGTERM)
            except ExternalProcessCleanupFailed as cleanup_exc:
                if hasattr(exc, "add_note"):
                    exc.add_note(f"External process cleanup also failed: {cleanup_exc}")
                else:
                    print(
                        f"outer exporter cleanup for {missing_cid} pid={process.pid} "
                        f"pgid={process.pid} after internal exception failed: {cleanup_exc}",
                        file=sys.stderr,
                    )
            raise
    finally:
        if can_install_handlers:
            for signum, previous in installed_handlers.items():
                signal.signal(signum, previous)

    if returncode != 0:
        if returncode < 0:
            status = f"terminated by signal {-returncode}"
        else:
            status = f"exit status {returncode}"
        raise ExportFailed(ExportFailure(missing_cid, command, status, "The synchronous export/import command returned failure."))

def pin_with_export_retry(
    cid: str,
    *,
    api: str = "http://127.0.0.1:5001",
    timeout: float | None = None,
    export_command: str | Path = DEFAULT_EXPORT_COMMAND,
    export_timeout: float | None = None,
    max_attempts: int = 0,
    recursive: bool = True,
    progress: bool = True,
    verbose: bool = False,
) -> PinResult:
    client = KuboClient(api, timeout=timeout)
    attempts = 0
    while True:
        attempts += 1
        result = client.pin_add(cid, recursive=recursive, progress=progress)
        if not result.errors:
            return result

        missing_cid = missing_block_cid(result)
        if not missing_cid or (max_attempts and attempts >= max_attempts):
            return result

        if verbose:
            print(f"pin attempt {attempts} is missing {missing_cid}; running synchronous export", file=sys.stderr)
        try:
            export_missing_cid(missing_cid, export_command, timeout=export_timeout)
        except ExportFailed as exc:
            return PinResult(result.progress, result.pins, result.cid, [*result.errors, exc.failure.as_error()], result.raw_events)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cid", help="Root CID to pin")
    parser.add_argument("--api", default="http://127.0.0.1:5001", help="Kubo RPC API URL or multiaddr")
    parser.add_argument("--timeout", type=float, default=None, help="Timeout in seconds for Kubo API operations")
    parser.add_argument("--export-command", default=DEFAULT_EXPORT_COMMAND, help="Synchronous exporter executable")
    parser.add_argument("--export-timeout", type=float, default=None, help="Timeout in seconds for the exporter; default is no timeout")
    parser.add_argument("--max-attempts", type=int, default=0, help="Maximum pin attempts; 0 means unlimited")
    parser.add_argument("--no-recursive", action="store_true", help="Pass recursive=false to pin/add")
    parser.add_argument("--no-progress", action="store_true", help="Pass progress=false to pin/add")
    parser.add_argument("-v", "--verbose", action="store_true", help="Log missing blocks to stderr")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    result = pin_with_export_retry(args.cid, api=args.api, timeout=args.timeout, export_command=args.export_command, export_timeout=args.export_timeout, max_attempts=args.max_attempts, recursive=not args.no_recursive, progress=not args.no_progress, verbose=args.verbose)
    if result.errors:
        for error in result.errors:
            print(f"Error: {error.message}", file=sys.stderr)
        return 1
    for pinned in result.pins:
        print(pinned)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
