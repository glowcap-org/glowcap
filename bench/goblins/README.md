# pancake and Goblins benchmark

This benchmark runs one Racket application in three series:
[Spritely Goblins](https://spritely.institute/goblins/), pancake's Racket
binding, and the same pancake binding with time travel enabled. It compares
latency, throughput, connection setup, and server memory.

The harness holds the application source, call shape, and loopback transport
constant. The runtimes and protocol implementations still differ, so read the
[methodology and caveats](METHODOLOGY.md) before interpreting a gap.

To compare client-language overhead against one fixed pancake host instead,
use [`zig build bench-langs`](../langs/README.md).

## Run it

Install `racket` and the `goblins` collection, then:

```sh
zig build bench-goblins
zig build bench-goblins -- --smoke
zig build bench-goblins -- --suite=registry
zig build bench-goblins -- --suite=echo --smoke
```

The command starts each server in its own process, waits for readiness, drives
the client, samples memory, and stops the server.

Generated reports go to `zig-out/bench-reports/`:

- `goblins-compare-<stamp>.txt`: the terminal report.
- `goblins-compare-<stamp>.md`: tables and Mermaid charts.
- `goblins-compare-<stamp>-latency.svg` and `-throughput.svg`: standalone
  charts.

Reports are not committed. They describe one run on one machine.

## What it runs

Each suite uses the same application source on both backends:

| Suite | Conversation |
| --- | --- |
| `echo` (S0) | One request and reply; no capability passing |
| `registry` (S1) | Look up a cell capability, then call `get` on it |
| `mint` (S2) | Create a purse capability and deposit into it |
| `taskboard` (S3) | Create a task, assign it, complete it, then read status |

Calls are sequential. The benchmark does not measure concurrent load or
promise pipelining.

## What it reports

- **Latency:** p50, p99, p999, and mean milliseconds.
- **Throughput:** completed units per second.
- **Connection setup:** total and per-connection time to connect and fetch the
  root capability.
- **Memory:** change in server RSS divided by open connections.

The memory figure includes the Racket binding and one green thread per
connection. It is not the Zig core's roughly 2 KiB design budget. RSS deltas
inside a much larger managed runtime are noisy; use them as an order-of-
magnitude comparison, not a precise allocation count.

## Snapshot and restore

Snapshot measurement is separate because pancake does not expose local
snapshot and restore through the C ABI used by the shared harness.

```sh
zig build bench-snapshot
racket bench/goblins/snapshot.rkt
```

Both commands sweep actor count and bytes per actor. The observed scaling
supports the expected O(objects) snapshot shape and no payload-byte copying;
it does not, by itself, prove the implementation mechanism. pancake snapshots
are opt-in per actor and use copy-on-write after a snapshot. Goblins shares
immutable behaviors through its runtime.

## Files

| Path | Role |
| --- | --- |
| `apps/` | Shared S0–S3 applications |
| `dispatch.rkt` | Substrate-independent method tables |
| `backend-goblins.rkt` | Goblins backend and TCP netlayer |
| `backend-pancake.rkt` | pancake Racket-binding backend |
| `backend-pancake-tt.rkt` | pancake backend with time travel enabled |
| `metrics.rkt` | Percentiles, throughput, and RSS sampling |
| `server.rkt`, `client.rkt` | Per-run processes |
| `bench.rkt` | Orchestration and comparison |
| `report.rkt` | Markdown and SVG output |
| `snapshot.rkt` | Goblins snapshot measurement |
| `*-test.rkt` | Harness unit tests |
