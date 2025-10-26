import argparse
import math
import os
import signal
import subprocess
import sys
import time

from datetime import datetime
from pathlib import Path
from typing import List, Tuple, Optional, Iterator

# --- graceful interrupt handling ---------------------------------------------

stop_requested = False  # set to True by SIGINT handler; finish current item then stop


def _handle_sigint(signum, frame):
    """
    First Ctrl-C: request a graceful stop after the current loop iteration finishes.
    Second Ctrl-C: exit immediately with code 130.
    """
    global stop_requested
    if not stop_requested:
        stop_requested = True
        sys.stderr.write(
            "\n[signal] SIGINT received — finishing current item, then exiting...\n"
            "[signal] Press Ctrl-C again to abort immediately.\n"
        )
        sys.stderr.flush()
    else:
        sys.stderr.write("\n[signal] Second SIGINT — exiting now.\n")
        sys.stderr.flush()
        os._exit(130)  # immediate exit; avoid throwing KeyboardInterrupt


def _install_signal_handlers():
    signal.signal(signal.SIGINT, _handle_sigint)


# --- CLI ---------------------------------------------------------------------

def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Hash leaf folders to IPFS, wrap them in an MFS-like DAG root, export as CAR; supports graceful SIGINT."
    )

    p.add_argument(
        "-n", "--dry-run",
        action="store_true",
        help=(
            "Do not modify the filesystem (no copies/moves/renames). "
            "Process ONLY the first eligible leaf. Still hashes and constructs the MFS DAG to show the actual final root CID to export."
        )
    )

    p.add_argument(
        "-1", "--one",
        action="store_true",
        help="Process exactly ONE eligible leaf directory fully, then exit."
    )

    # Future flags could go here (e.g., --api, --export-dir, etc.)
    return p.parse_args(argv)


# --- helpers -----------------------------------------------------------------

def run_ipfs(args: List[str], *, cwd: Optional[Path] = None) -> str:
    """
    Run an ipfs command and return stdout as a stripped string.
    """
    out = subprocess.check_output(args, shell=False, cwd=cwd).decode().strip()
    return out

# --- shell detection / console capabilities ----------------------------------

def detect_shell() -> str:
    """
    Best-effort detection of the invoking shell.
    Returns one of: 'powershell', 'bash', 'cmd', 'unknown'
    """
    env = os.environ
    # Strong hints for PowerShell
    if env.get('PSModulePath') or env.get('POWERSHELL_DISTRIBUTION_CHANNEL'):
        return 'powershell'
    # GitHub Actions / Windows Terminal run PowerShell too, but above usually present.
    # bash/zsh/etc on Unix
    sh = (env.get('SHELL') or '').lower()
    if 'bash' in sh:
        return 'bash'
    # Classic Windows CMD
    if os.name == 'nt' and (env.get('ComSpec') or '').lower().endswith('cmd.exe'):
        # If PS vars present we would have exited earlier, so this is probably cmd
        return 'cmd'
    return 'unknown'


def ansi_supported() -> bool:
    """
    Heuristic for ANSI escape support on this console.
    """
    if not sys.stdout.isatty():
        return False

    if os.name != 'nt':
        # Most POSIX ttys support ANSI unless TERM is dumb
        term = os.environ.get('TERM', '')
        return term and term.lower() != 'dumb'

    # Windows: detect common ANSI-capable hosts/terminals
    env = os.environ
    return bool(
        env.get('ANSICON') or          # ConEmu/ANSI shim
        env.get('WT_SESSION') or       # Windows Terminal
        env.get('ConEmuANSI') == 'ON' or
        env.get('TERM')                # e.g., xterm-256color on msys/cygwin
    )


def copy_large_file(src, dst):
    '''
    Copy a large file showing progress.
    '''
    shell_kind = detect_shell()
    use_ansi = ansi_supported()

    def write_status(line_builder=[0]):  # line_builder[0] keeps last length (mutable default trick)
        line = status_parts()
        if use_ansi:
            # Clear-to-EOL then write
            sys.stdout.write('\r\033[K' + line)
        else:
            # Overwrite line with padding so leftover characters are erased
            last_len = line_builder[0]
            pad = max(0, last_len - len(line))
            sys.stdout.write('\r' + line + (' ' * pad))
            line_builder[0] = len(line)
        sys.stdout.flush()

    print('copying "{}" --> "{}"'.format(src, dst))
    if os.path.exists(src) is False:
        print('ERROR: file does not exist: "{}"'.format(src))
        sys.exit(1)
    if os.path.exists(dst) is True:
        os.remove(dst)
    if os.path.exists(dst) is True:
        print('ERROR: file exists, cannot overwrite it: "{}"'.format(dst))
        sys.exit(1)

    # Start the timer and get the size.
    start = time.time()
    size = os.stat(src).st_size
    print('{} bytes'.format(size))

    # Adjust the chunk size to the input size.
    divisor = 10000  # .1%
    chunk_size = math.ceil(size / divisor)
    while chunk_size == 0 and divisor > 0:
        divisor /= 10
        chunk_size = size / divisor
    print('chunk size is {}'.format(chunk_size))

    def status_parts():
        per = 100. * float(copied) / float(size) if copied else 0.0
        elapsed = time.time() - start if copied else 0.0
        avg_time_per_byte = (elapsed / float(copied)) if copied else 0.0
        remaining = size - copied
        est = remaining * avg_time_per_byte if copied else 0.0
        est1 = size * avg_time_per_byte if copied else 0.0

        # Slightly different phrasing for PowerShell (no fancy symbols)
        if shell_kind == 'powershell' and not use_ansi:
            return "{:>6.1f}%  rem={:>.1f}s, tot={:>.1f}s  {} -> {}".format(
                per, est, est1, src, dst
            )
        else:
            # Same text, ANSI-capable consoles will also get the clear-to-EOL
            return "{:>6.1f}%  rem={:>.1f}s, tot={:>.1f}s  {} -> {}".format(
                per, est, est1, src, dst
            )

    # Copy.
    try:
        with open(src, 'rb') as ifp, open(dst, 'wb') as ofp:
            copied = 0  # bytes
            chunk = ifp.read(int(chunk_size))
            while chunk:
                ofp.write(chunk)
                copied += len(chunk)
                write_status()
                chunk = ifp.read(int(chunk_size))

    except IOError as obj:
        print('\nERROR: {}'.format(obj))
        sys.exit(1)

    # Final line cleanup
    if use_ansi:
        sys.stdout.write('\r\033[K')
    else:
        # Overwrite any residual characters from the last status line
        sys.stdout.write('\r' + ' ' * 120 + '\r')
    elapsed = time.time() - start
    print('copied "{}" --> "{}" in {:>.1f}s"'.format(src, dst, elapsed))


def ensure_running_from_downloads_or_exit() -> Tuple[Path, str]:
    """
    Validates that CWD is .../<Parent>/Downloads and that <Parent> is allowed.
    Returns (downloads_dir, parent_name).
    """
    current_dir = Path.cwd().resolve()
    allowed_parents = {"Laptop", "Mimas", "Ananke", "Janus"}
    parent_name = current_dir.parent.name

    # Must be Downloads
    if current_dir.name != "Downloads":
        sys.stderr.write(
            f"[error] This tool must be run from a 'Downloads' directory. "
            f"Current directory is: {current_dir}\n"
        )
        sys.exit(2)

    # Parent must be one of allowed
    if parent_name not in allowed_parents:
        sys.stderr.write(
            "[error] The parent of 'Downloads' must be one of: "
            f"{', '.join(sorted(allowed_parents))}. "
            f"Detected parent: '{parent_name}' (full path: {current_dir.parent})\n"
        )
        sys.exit(2)

    return current_dir, parent_name


def has_subdirectories(p: Path) -> bool:
    """Return True if directory `p` contains any subdirectories (ignores files)."""
    try:
        for child in p.iterdir():
            if child.is_dir():
                return True
        return False
    except PermissionError:
        # If we can't read it, treat as having children to be safe (skip as non-leaf).
        return True
    except FileNotFoundError:
        # Raced out of existence; not a leaf we can process now.
        return True

def collect_leaf_dirs(downloads_dir: Path) -> Iterator[Path]:
    """
    Generator that yields every LEAF directory (contains no subdirectories)
    under `downloads_dir` at ANY depth.

    Strategy:
      1) Look only at the immediate children of `downloads_dir` and sort those
         top-level directories by creation time (oldest first).
      2) For each top-level directory (in that order), walk its subtree and
         yield leaf directories *as soon as they are found*.

    Notes:
      - The `downloads_dir` itself is never yielded.
      - We do not sort deeper levels; we yield as they are discovered to start
        processing ASAP.
    """
    # Gather and sort ONLY the first level of subdirectories by ctime.
    try:
        top_dirs = [p for p in downloads_dir.iterdir() if p.is_dir()]
    except (PermissionError, FileNotFoundError):
        top_dirs = []

    def _ctime_or_inf(p: Path) -> float:
        try:
            return p.stat().st_ctime
        except OSError:
            # If stat fails, push it to the end deterministically.
            return float("inf")

    top_dirs.sort(key=lambda p: (_ctime_or_inf(p), str(p)))

    # Walk each top-level dir (oldest first) and yield leaf dirs immediately.
    for top in top_dirs:
        for root, dirs, files in os.walk(top, topdown=True, onerror=lambda e: None):
            # A leaf directory has no subdirectories.
            if not dirs:
                p = Path(root)
                # Exclude the Downloads root defensively.
                if p.resolve() != downloads_dir.resolve():
                    yield p


def is_dir_empty(p: Path) -> bool:
    try:
        next(p.iterdir())
        return False
    except StopIteration:
        return True
    except (PermissionError, FileNotFoundError):
        # If unreadable or raced away, treat as non-empty to avoid destructive ops.
        return False


def build_mfs_items_for_dir(target_dir: Path, downloads_dir: Path, parent_name: str) -> List[str]:
    """
    Construct the list of path names for the synthetic MFS DAG we build around the leaf.
    Order is **deepest-first**, then 'Downloads', then the device parent.
    Example:
      target_dir = .../Laptop/Downloads/2024-01-10/ClientX/Photos
      rel parts from Downloads = ('2024-01-10','ClientX','Photos')
      mfs_items = ['Photos','ClientX','2024-01-10','Downloads','Laptop']
    """
    rel = target_dir.relative_to(downloads_dir)
    rel_parts = list(rel.parts)
    rel_parts.reverse()  # deepest first
    return rel_parts + [downloads_dir.name, parent_name]


def build_nested_mfs_root(api_addr: str, leaf_cid: str, names_deepest_first: List[str]) -> Tuple[str, List[Tuple[str, str]]]:
    """
    Build a *nested* MFS-like DAG where each name becomes a parent directory
    containing the previous CID as a link. This yields a single root that wraps
    the whole structure.

    IMPORTANT:
      - We are *nesting* links: parent -> child -> ... -> leaf (leaf = actual dir).
      - This differs from adding multiple sibling links pointing to the same leaf.

    Returns:
      mfs_root_cid, steps
      where steps is a list of (name, new_parent_cid) in the order they were created.
    """
    steps: List[Tuple[str, str]] = []
    child_cid = leaf_cid  # start from the actual directory CID
    for name in names_deepest_first:
        # Create an empty dir to act as the new parent
        new_parent = run_ipfs(['ipfs', '--api', api_addr, 'object', 'new', 'unixfs-dir'])
        # Add a single link from the new parent to the current child
        new_parent = run_ipfs(['ipfs', '--api', api_addr, 'object', 'patch', 'add-link', '--',
                               new_parent, name, child_cid])
        steps.append((name, new_parent))
        # The newly created parent becomes the next child up the chain
        child_cid = new_parent
    # After the loop, child_cid is the final root CID that wraps the entire MFS structure
    return child_cid, steps


def processed_destination_path(target_dir: Path, downloads_dir_name: str = "Downloads",
                               processed_root_name: str = "Downloads-Processed") -> Path:
    """
    Replace the first 'Downloads' component in the absolute path with 'Downloads-Processed'.
    """
    parts = list(target_dir.parts)
    try:
        idx = parts.index(downloads_dir_name)
    except ValueError:
        # Shouldn't happen since target_dir is under Downloads, but be defensive
        idx = None

    if idx is not None:
        parts[idx] = processed_root_name
    return Path(*parts)


# --- main --------------------------------------------------------------------

def main():
    _install_signal_handlers()
    args = parse_args()

    DRY = args.dry_run
    api = '/ip4/127.0.0.1/tcp/5001'

    downloads_dir, parent_name = ensure_running_from_downloads_or_exit()

    # Collect only LEAF directories (any depth) under Downloads
    targets = collect_leaf_dirs(downloads_dir)

    processed_one_in_dry_run = False

    processed_one_and_quit = False

    for target_dir in targets:

        # If a graceful stop was requested, do not start a new item.
        if stop_requested:
            print("[stop] Stop requested. Exiting before starting a new directory.")
            break

        # Skip if somehow the target is the root itself (defensive)
        if target_dir.resolve() == downloads_dir:
            continue

        # Handle empty leaf directories (delete or preview deletion)
        if is_dir_empty(target_dir):
            print('Empty dir ', target_dir)
            if not DRY:
                try:
                    target_dir.rmdir()
                except OSError as e:
                    # Could be not empty due to races; just note it.
                    print(f"[warn] Failed to remove (race or permissions?): {target_dir} -> {e}")
            else:
                print('[dry-run] Would remove empty directory:', target_dir)
            # After finishing this short iteration, respect any pending stop.
            if stop_requested:
                print("[stop] Stop requested. Exiting after finishing current directory.")
                break
            continue

        print(f"path={target_dir}")

        # --- 1) Hash the leaf directory to get the directory CID (this is the actual content) ---
        # NOTE: In DRY mode we still hash and also build the MFS DAG so you can see the real export root.
        dir_cid = run_ipfs(['ipfs', '--api', api, 'add', '-Q', '-r', '--pin=false', '.'], cwd=target_dir)
        print(f"[info] dir_cid={dir_cid}  path={target_dir}")

        # Build the list of MFS names (deepest-first, then 'Downloads', then the device parent)
        mfs_items = build_mfs_items_for_dir(target_dir, downloads_dir, parent_name)

        # --- 2) Build the *nested* MFS DAG up to the synthetic root and capture the final root CID ---
        #     This was the previous bug: we exported the directory CID instead of the *root* that wraps it.
        mfs_root_cid, mfs_steps = build_nested_mfs_root(api, dir_cid, mfs_items)
        print(f"[info] mfs_root_cid={mfs_root_cid} (final export root)")

        # For visibility, show each nesting step (from deepest name up to parent/device)
        for name, parent_cid in mfs_steps:
            print(f"[mfs] parent_dir_cid={parent_cid}  contains link '{name}' -> child")

        # Compute output/copy/rename destinations
        car_out = Path('H:/', 'ipfs-export', mfs_root_cid + '.car')   # export the *MFS root* CID
        copy_dest = Path('X:', 'data', 'ipfs-staging', mfs_root_cid + '.car')
        final_dest = Path('X:', 'data', 'ipfs-export', mfs_root_cid + '.car')

        # Construct new dest path for the processed folder rename
        dest_target_dir = processed_destination_path(target_dir)

        # --- DRY RUN: fully construct the DAG (done above), but do NOT export/copy/move/rename ---
        if DRY:
            print('[dry-run] First item only. No filesystem changes will be made.')
            print('[dry-run] Leaf directory CID (dir_cid):', dir_cid)
            print('[dry-run] MFS nesting order (deepest → parent):')
            for m in mfs_items:
                print('           -', m)
            print('[dry-run] Final MFS root CID (mfs_root_cid):', mfs_root_cid)
            print('[dry-run] Would export CAR from:', mfs_root_cid, 'to', car_out)
            print('[dry-run] Would copy staging CAR to:', copy_dest)
            print('[dry-run] Would move final CAR to:', final_dest)
            print('[dry-run] Would ensure parent exists for rename:', dest_target_dir.parent)
            print('[dry-run] Would rename source dir -->', dest_target_dir)
            processed_one_in_dry_run = True
            # Only preview the first eligible item
            break

        # --- REAL MODE: export the *MFS root* CID, not the raw directory CID ---
        print(car_out)
        process = subprocess.Popen(
            ['ipfs', '--api', api, 'dag', 'export', '-p', mfs_root_cid],
            stdout=car_out.open('+w'),
            stderr=subprocess.PIPE
        )
        for c in iter(lambda: process.stderr.read(1), b""):
            sys.stdout.buffer.write(c)

        copy_large_file(car_out, copy_dest)
        copy_dest.rename(final_dest)
        car_out.unlink()

        if not dest_target_dir.parent.exists():
            dest_target_dir.parent.mkdir(exist_ok=True, parents=True)
            print('Created dir', dest_target_dir.parent)

        try:
            target_dir.rename(dest_target_dir)
        except OSError as e:
            print(f"[warn] Failed to rename {target_dir} -> {dest_target_dir}: {e}")

        # Iteration for this target_dir is now finished.
        # If a graceful stop was requested during the work above,
        # exit *before* starting the next item.
        if stop_requested:
            print("[stop] Stop requested. Exiting after finishing current item.")
            break
        if args.one:
            print("[one] Completed exactly one item. Exiting now.")
            processed_one_and_quit = True
            break


    if stop_requested:
        print("[stop] Clean exit after finishing the current work item.")
    elif args.one:
        if processed_one_and_quit:
            print("[one] Finished one item and exited cleanly.")
        else:
            print("[one] No eligible items found.")
    elif DRY:
        if processed_one_in_dry_run:
            print("[dry-run] Preview complete.")
        else:
            print("[dry-run] No eligible items found to preview.")
    else:
        print("[done] Completed all work.")

if __name__ == "__main__":
    main()
