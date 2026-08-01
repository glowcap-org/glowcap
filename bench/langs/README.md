# Per-language consumer cost

This benchmark asks what a client written in each supported language pays to run
the same application against one native Zig pancake host.

The host and task-board workload stay fixed. The client changes between Deno,
Python, Rust, Racket, native Zig, and Spritely Goblins as a reference CapTP peer.
Each row therefore measures a whole consumer stack: runtime, binding, garbage
collector, and the application written in that language.

It is not a language leaderboard. Results describe one machine and one run, and
the rows do not isolate pancake's wire cost from their runtimes.

## Run it

```sh
zig build bench-langs                  # every available client
zig build bench-langs -- --smoke       # small counts
zig build bench-langs -- --client=zig  # one client
```

The native Zig host always runs. A normal run includes the Zig client; a
`--client` filter may select another row instead. Optional rows join when their
runtimes are on `PATH`, and unavailable clients are reported and skipped.

Reports are written under `zig-out/bench-reports/` with a timestamp:

- a terminal-style text report;
- a Markdown table and charts;
- standalone SVG charts for latency, throughput, and cold start.

Generated reports are not committed. Keep the report with the machine and run
conditions needed to interpret it.

## What it measures

| Metric | Meaning |
| --- | --- |
| Latency | Sequential task-board units, reported as p50, p99, p999, and mean milliseconds. |
| Throughput | Pipelined task-board units per second. |
| Session setup | Time to open sessions and fetch the root capability. |
| Memory | Change in client-process RSS divided by open connections. |
| Local turn | In-language actor dispatch compared with a loopback path through the C host machinery. |
| Cold start | Process spawn through one completed task-board unit. |

One task-board unit creates a task, assigns it, completes it, and reads its
status. Latency waits after each operation. Throughput addresses dependent calls
at the unresolved answer, so the four operations travel as one pipelined
flight.

Memory is an operating-system RSS delta, not a binding-heap or allocation
measurement. A managed runtime may absorb connection buffers inside an existing
heap without changing RSS, so compare a row with itself across runs—not against
a different runtime class.

The local-turn `via_host` figure is not a prediction of a future Zig-vat path.
It measures the existing loopback route through the C host, including wire
encoding. A future local path could differ in either direction.

Read [Methodology and caveats](methodology.md) before comparing results. The
exact client protocol is in [`contract.md`](contract.md).

To compare pancake and Goblins while holding the Racket application source,
call shape, and loopback transport constant, use the separate
[pancake and Goblins benchmark](../goblins/README.md).

## Files

| Path | Role |
| --- | --- |
| [`host.zig`](host.zig) | Fixed native Zig task-board host. |
| [`orchestrator.zig`](orchestrator.zig) | Runs clients, samples processes, and writes reports. |
| [`contract.md`](contract.md) | NDJSON schema and workload required of every client. |
| [`clients/`](clients/) | One benchmark client per language. |
