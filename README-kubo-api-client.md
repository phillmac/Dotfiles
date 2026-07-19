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

## Retrying pins through an export queue socket

When a node is offline and `ipfs pin add --progress <cid>` fails because a child
block is missing locally, `pin_with_export_queue.py` can retry the pin, enqueue
the missing block CID on a Unix socket, wait for that socket request to finish,
and retry the original pin. This is intended for sockets serviced by export
functions such as `rhea.wasabi.pebble.export.laptop.dag`.

```sh
./pin_with_export_queue.py QmhashA /path/to/export-queue.sock --api http://127.0.0.1:5001 --verbose
```

For the example error below, the script extracts `QmhashB`, writes `QmhashB\n`
to the export queue socket, waits for the socket server to close the response,
and then retries pinning `QmhashA`.

```text
Error: pin: block was not found locally (offline): ipld: could not find QmhashB
```

Useful options:

- `--max-attempts N` stops after `N` pin attempts; the default `0` retries until
  success or until Kubo returns an error that does not include a missing block.
- `--timeout SECONDS` applies to both Kubo API calls and queue socket operations.
- `--retry-delay SECONDS` sleeps briefly after each export completes before the
  next pin attempt.
