# Per-language consumer cost

This benchmark asks what a client written in each supported language pays to run
the same application against one Zig glowcap host.

The host and task-board workload stay fixed, and the client changes between
languages, with Spritely Goblins as a reference CapTP peer. The `Kind` enum in
[`orchestrator.zig`](orchestrator.zig) names the clients.
Each row measures a whole consumer stack: runtime, binding, garbage collector,
and the application written in that language. The rows mix glowcap's wire cost
with that language's runtime, and results describe one machine and one run.

## Run it

```sh
zig build bench-langs                  # every available client
zig build bench-langs -- --smoke       # small counts
zig build bench-langs -- --client=zig  # one client
zig build bench-langs -- --pin=2,3     # clients on core 2, the host on core 3
```

The Zig host always runs. A normal run includes the Zig client, and a
`--client` filter can select another row instead. Optional rows join when their
runtimes are on `PATH`, and unavailable clients are reported and skipped.
`--pin=A,B` holds every client on core A and the host on core B, the placement
the site report uses, so two runs of one row do not differ by where the
scheduler put each process. The `local` window's client carries its own host,
so it gets both cores.

Reports are written under `zig-out/bench-reports/` with a timestamp:

- a terminal-style text report
- a Markdown table and charts
- standalone SVG charts for latency, throughput, and cold start

Reports are not committed. Keep each with the machine and run conditions it
needs.

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

Memory is an operating-system RSS delta. A managed runtime can absorb
connection buffers inside an existing heap without changing RSS, so compare a
row with itself across runs, not against a different runtime class.

Read [Methodology and caveats](methodology.md) before comparing results. The
exact client protocol is in [`contract.md`](contract.md).

To compare glowcap and Goblins while holding the Racket application source,
call shape, and loopback transport constant, use the separate
[glowcap and Goblins benchmark](../goblins/README.md).

## Files

| Path | Role |
| --- | --- |
| [`host.zig`](host.zig) | Fixed Zig task-board host. |
| [`orchestrator.zig`](orchestrator.zig) | Runs clients, samples processes, and writes reports. |
| [`availability.zig`](availability.zig) | Which client rows join a run, and the builds and precompiles a row needs first. |
| [`contract.md`](contract.md) | NDJSON schema and workload required of every client. |
| [`clients/`](clients/) | One benchmark client per language. |
