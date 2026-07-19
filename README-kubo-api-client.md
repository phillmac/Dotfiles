# Kubo Python API client

`kubo_api_client.py` is a small dependency-free client for the Kubo daemon HTTP
RPC API. The Kubo CLI uses the same `/api/v0` command layer as the daemon API;
this client calls `/api/v0/add` and `/api/v0/pin/add` directly and keeps streamed
progress objects separate from final status objects.

## Reference behavior

Research notes from the official Kubo repository:

- `core/commands/add.go` defines `AddEvent` with `Name`, `Hash`, `Bytes`, `Size`,
  mode, and mtime fields. During CLI post-processing, add events with `Hash` are
  printed as final `added <cid> <name>` lines, while events with only `Bytes` are
  progress updates.
- `core/commands/pin/pin.go` defines `AddPinOutput` with `Pins`, `Progress`, and
  `Bytes`. With `--progress`, Kubo streams progress objects without `Pins` and
  emits a final object containing `Pins`.
- Kubo release notes for newer versions mention `ipfs pin add --progress` showing
  fetched/processed node counts and total bytes, so the client accepts progress
  events both with and without the `Bytes` field for compatibility.
- Older `/api/v0/add` responses are newline-delimited JSON objects rather than a
  single JSON array; this client parses the response line by line.

## Usage

```python
from kubo_api_client import KuboClient

client = KuboClient("http://127.0.0.1:5001", timeout=3600)

add_result = client.add("./data", recursive=True, wrap_with_directory=True)
print(add_result.cid)          # final root CID
print(add_result.entries)      # final file/directory listing events
print(add_result.progress)     # byte progress events
print(add_result.errors)       # structured Kubo/transport errors

pin_result = client.pin_add(add_result.cid, recursive=True, progress=True)
print(pin_result.cid)          # final pinned CID
print(pin_result.pins)         # all final pins returned by Kubo
print(pin_result.progress)     # fetched/processed progress events
print(pin_result.errors)
```

Options are passed through to Kubo after converting underscores to hyphens, so
`cid_version=1` becomes `cid-version=1` and newer daemon options can be used
without changing the client.

## Exporting missing DAGs for pin recovery

Two workflows are supported for exporting a child DAG from the laptop IPFS API
and importing it into the Rhea IPFS API. Both workflows use the same synchronous
exporter executable, `.bashrc.d/carpo.bashrc.d/rhea-wasabi-pebble-export-laptop-dag-sync`, and therefore
share the same `flock` lock. Queue-triggered exports and direct pin-recovery
exports can run at the same time, but only one Docker/`mbuffer` export/import
pipeline runs at once.

### Queue worker

The long-running Bash function `rhea.wasabi.pebble.export.laptop.dag` still
accepts newline-delimited CIDs through the existing FIFO:

```text
rhea.wasabi.pebble.export.laptop.dag.queue
```

Start the worker in a shell that has `.bashrc.d/carpo.bashrc.d/ipfs.bashrc`
loaded, then write CIDs to the FIFO as before. A FIFO write only queues work for
the worker; it does not mean the export/import has completed.

### Synchronous pin recovery

When a node is offline and `ipfs pin add --progress <cid>` fails because a child
block is missing locally, `pin_with_export_retry.py` pins the original root CID,
parses the missing child CID from Kubo's error, directly invokes the synchronous
exporter for that child, waits until `ipfs dag import --pin-roots=false
--allow-big-block` succeeds on Rhea, and immediately retries the original root
pin. The Python workflow does not communicate through the FIFO.

```sh
./pin_with_export_retry.py ROOT_CID \
    --api http://127.0.0.1:5001 \
    --export-command .bashrc.d/carpo.bashrc.d/rhea-wasabi-pebble-export-laptop-dag-sync \
    --verbose
```

Useful options:

- `--max-attempts N` stops after `N` pin attempts; the default `0` retries until
  success or until Kubo returns an error that does not include a missing block.
- `--timeout SECONDS` applies only to Kubo API calls.
- `--export-timeout SECONDS` limits the synchronous exporter; the default is no
  exporter timeout so large DAG exports can complete.
- `--export-command PATH` defaults to the exporter under the sourced dotfiles
  tree: `.bashrc.d/carpo.bashrc.d/rhea-wasabi-pebble-export-laptop-dag-sync`.
  The FIFO worker resolves the same default relative to `ipfs.bashrc`, so the
  normal dotfiles symlink/source installation does not need the repository root
  in `PATH`.
- `RHEA_WASABI_PEBBLE_EXPORT_LAPTOP_DAG_SYNC` overrides the FIFO worker's
  exporter path.
- `IPFS_LAPTOP_API_SOCKET`, `RHEA_IPFS_WASABI_SOCKET`,
  `LAPTOP_IPFS_CLI_IMAGE`, `RHEA_IPFS_CLI_IMAGE`, and `IPFS_DAG_RETRY_DELAY`
  keep their exporter meanings for sockets, Docker images, and internal retry
  backoff.
- `IPFS_DAG_EXPORT_LOCK` overrides the shared lock path. By default it is
  `${HOME}/.var/run/rhea-wasabi-pebble-export-laptop-dag.lock`.
- `IPFS_DAG_EXPORT_TERMINATE_TIMEOUT` controls the Bash pipeline cleanup grace
  period and accepts non-negative numeric values, including fractional seconds.
  Python derives its exporter process-group cleanup wait from this value plus a
  fixed safety margin, capped to avoid unbounded waits.

Signal and retry behaviour:

- Python starts the exporter in its own process group. Ctrl+C, SIGTERM,
  `--export-timeout`, and unexpected exceptions terminate that complete exporter
  process group, wait briefly, and then escalate to SIGKILL if needed. Expected
  exporter launch failures, nonzero exits, signal exits, and timeouts are reported
  as structured pin errors; Ctrl+C and SIGTERM keep normal interrupt/termination
  semantics instead of becoming ordinary pin failures.
- The synchronous Bash exporter owns the shared `flock`, signal traps, active
  pipeline PID, and active pipeline process-group ID in the same Bash process.
  The exporter keeps the lock descriptor private: active test hooks and the real
  Docker/`mbuffer` pipeline close FD 9 before running. Helper children created
  after lock acquisition, including lock polling and retry-sleep helpers, also
  close FD 9, so surviving children cannot keep the shared lock held after the
  exporter exits.
- Active pipeline cleanup is bounded. Shutdown first sends SIGTERM to the
  dedicated pipeline process group, waits up to
  `IPFS_DAG_EXPORT_TERMINATE_TIMEOUT` seconds (default `5`), escalates to
  SIGKILL if the group remains, reaps the tracked child, and logs the cleanup
  steps to stderr.
- Signalling only the Bash exporter PID interrupts lock acquisition polling,
  active pipeline execution, and internal retry delays. The exporter does not
  start another export attempt after shutdown begins, and the lock is released
  after success, ordinary failure, SIGINT, SIGTERM, and forced cleanup.
- The FIFO worker runs in a subshell, so its INT/TERM traps are scoped to the
  worker and do not alter the calling interactive shell. It runs the active
  exporter and retry-delay sleep as tracked children, making PID-only SIGINT and
  SIGTERM interrupt foreground exporter waits and retry delays promptly. If the
  exporter fails for a queued CID, the worker logs the original status and
  retries that same CID after `IPFS_DAG_RETRY_DELAY`; it does not read the next
  FIFO CID until the current CID succeeds.
