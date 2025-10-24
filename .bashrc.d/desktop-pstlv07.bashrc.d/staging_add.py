import argparse
import math
import os
import signal
import subprocess
import sys
import time

from datetime import datetime
from pathlib import Path

# from b2sdk.v2 import ScanPoliciesManager
# from b2sdk.v2 import parse_folder
# from b2sdk.v2 import Synchronizer
# from b2sdk.v2 import SyncReport

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
        description="Hash folders to IPFS, export as CAR, copy/move results; supports graceful SIGINT."
    )
    p.add_argument(
        "-n", "--dry-run",
        action="store_true",
        help=(
            "Do not modify anything. Process ONLY the very first item: hash it with IPFS to get the base CID, "
            "then print all the paths and the actions that would happen (MFS links, export, copies, renames)."
        )
    )
    # Future flags could go here (e.g., --api, --export-dir, etc.)
    return p.parse_args(argv)


# --- helpers -----------------------------------------------------------------

def copy_large_file(src, dst):
    '''
    Copy a large file showing progress.
    '''
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

    # Copy.
    try:
        with open(src, 'rb') as ifp:
            with open(dst, 'wb') as ofp:
                copied = 0  # bytes
                chunk = ifp.read(chunk_size)
                while chunk:
                    ofp.write(chunk)
                    copied += len(chunk)
                    per = 100. * float(copied) / float(size)

                    # Estimated time
                    elapsed = time.time() - start
                    avg_time_per_byte = elapsed / float(copied)
                    remaining = size - copied
                    est = remaining * avg_time_per_byte
                    est1 = size * avg_time_per_byte
                    eststr = 'rem={:>.1f}s, tot={:>.1f}s'.format(est, est1)

                    # Status line
                    sys.stdout.write('\r\033[K{:>6.1f}%  {}  {} --> {} '.format(per, eststr, src, dst))
                    sys.stdout.flush()

                    chunk = ifp.read(chunk_size)

    except IOError as obj:
        print('\nERROR: {}'.format(obj))
        sys.exit(1)

    sys.stdout.write('\r\033[K')  # clear to EOL
    elapsed = time.time() - start
    print('copied "{}" --> "{}" in {:>.1f}s"'.format(src, dst, elapsed))


def ensure_running_from_downloads_or_exit() -> tuple[Path, str]:
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


def collect_leaf_dirs(downloads_dir: Path) -> list[Path]:
    """
    Collect every subdirectory under `downloads_dir` at ANY depth that is a LEAF
    (contains no subdirectories). The top-level `downloads_dir` itself is excluded.
    Sorted by creation time (oldest first), then path for stability.
    """
    # All directories except the top-level Downloads itself
    all_dirs = [p for p in downloads_dir.rglob('*') if p.is_dir()]
    leaf_dirs = []
    for p in all_dirs:
        # Defensive filter: exclude the root (shouldn't be present anyway)
        if p.resolve() == downloads_dir:
            continue
        if not has_subdirectories(p):
            leaf_dirs.append(p)

    # Sort by ctime; if equal, fallback to path for stable ordering
    leaf_dirs.sort(key=lambda p: (p.stat().st_ctime, str(p)))
    return leaf_dirs


def is_dir_empty(p: Path) -> bool:
    try:
        next(p.iterdir())
        return False
    except StopIteration:
        return True
    except (PermissionError, FileNotFoundError):
        # If unreadable or raced away, treat as non-empty to avoid destructive ops.
        return False


def build_mfs_items_for_dir(target_dir: Path, downloads_dir: Path, parent_name: str) -> list[str]:
    """
    Construct MFS names list using the detected parent.
    Start with the deepest directory name and walk upward to 'Downloads',
    then append 'Downloads' and the detected parent.

    Example:
      target_dir = .../Laptop/Downloads/2024-01-10/ClientX/Photos
      rel parts from Downloads = ('2024-01-10','ClientX','Photos')
      mfs_items = ['Photos','ClientX','2024-01-10','Downloads','Laptop']
    """
    rel = target_dir.relative_to(downloads_dir)
    rel_parts = list(rel.parts)
    rel_parts.reverse()  # deepest first
    return rel_parts + [downloads_dir.name, parent_name]


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
    api = ['/ip4/127.0.0.1/tcp/5001']

    downloads_dir, parent_name = ensure_running_from_downloads_or_exit()

    # Collect only LEAF directories (any depth) under Downloads
    targets = collect_leaf_dirs(downloads_dir)

    processed_one_in_dry_run = False

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

        # --- DRY-RUN special behavior: only "load" (hash) the very first item, print everything, then exit ---
        if DRY and processed_one_in_dry_run:
            # We already demonstrated the first item; stop before doing more.
            break

        # Always hash the directory to get a base CID (this is the "load" in dry-run).
        # In DRY mode we *only* do this hashing step and then print what would happen.
        base_cid = subprocess.check_output(
            ['ipfs', '--api', api[0], 'add', '-Q', '-r', '--pin=false', '.'],
            shell=False,
            cwd=target_dir
        ).decode().strip()

        print(base_cid, target_dir)

        # Use the detected parent and enforce `Downloads` as the fixed ancestor.
        mfs_items = build_mfs_items_for_dir(target_dir, downloads_dir, parent_name)

        # Compute output/copy/rename destinations
        out_file = Path('H:/', 'ipfs-export', base_cid + '.car')
        copy_dest = Path('X:', 'data', 'ipfs-staging', base_cid + '.car')
        final_dest = Path('X:', 'data', 'ipfs-export', base_cid + '.car')

        # Construct new dest path for the processed folder rename
        dest_target_dir = processed_destination_path(target_dir)

        if DRY:
            print('[dry-run] First item only. No changes will be made.')
            print('[dry-run] Hashed directory (base CID):', base_cid)
            print('[dry-run] Source dir:', target_dir)
            print('[dry-run] Detected top-level parent:', parent_name)
            print('[dry-run] Would create/attach MFS links in order:')
            for m in mfs_items:
                print('           - name:', m)
            print('[dry-run] Would export CAR to:', out_file)
            print('[dry-run] Would copy staging CAR to:', copy_dest)
            print('[dry-run] Would move final CAR to:', final_dest)
            print('[dry-run] Would ensure parent exists for rename:', dest_target_dir.parent)
            print('[dry-run] Would rename source dir -->', dest_target_dir)
            print('[dry-run] Completed preview of first item. Exiting.')
            processed_one_in_dry_run = True
            break

        # --- real mode below (process the leaf) ---

        # Create an empty root to add links to
        empty_cid = subprocess.check_output(
            ['ipfs', '--api', api[0], 'object', 'new', 'unixfs-dir'],
            shell=False
        ).decode().strip()

        # Attach links in MFS-like structure (one link per name at the root)
        for mfs_item in mfs_items:
            empty_cid = subprocess.check_output(
                ['ipfs', '--api', api[0], 'object', 'patch', 'add-link', '--',
                 empty_cid, mfs_item, base_cid],
                shell=False
            ).decode().strip()
            print(empty_cid, mfs_item)

        print(out_file)
        process = subprocess.Popen(
            ['ipfs', '--api', api[0], 'dag', 'export', '-p', base_cid],
            stdout=out_file.open('+w'),
            stderr=subprocess.PIPE
        )
        for c in iter(lambda: process.stderr.read(1), b""):
            sys.stdout.buffer.write(c)

        copy_large_file(out_file, copy_dest)
        copy_dest.rename(final_dest)
        out_file.unlink()

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

    if stop_requested:
        print("[stop] Clean exit after finishing the current work item.")
    else:
        if DRY:
            if processed_one_in_dry_run:
                print("[dry-run] Preview complete.")
            else:
                print("[dry-run] No eligible items found to preview.")
        else:
            print("[done] Completed all work.")


if __name__ == "__main__":
    main()
