# Per-language benchmark methodology

The benchmark holds one native Zig host and one application contract constant,
then replaces the client stack. This page records how the measurements are made
and where comparisons stop being meaningful.

## Shared workload

Every client implements the NDJSON protocol in [`contract.md`](contract.md).
One unit performs four operations against a task board:

1. create a task capability;
2. assign the task;
3. complete it;
4. read and verify its final status.

All clients use loopback TCP. The transport disables Nagle for each peer.
Networked measurement windows start a fresh ReleaseFast host, so heap growth
from one window does not carry into the next.

Latency runs the four dependent calls sequentially. Throughput pipelines them:
the calls after `create` are sent to its unresolved answer, and only the final
status is settled. Goblins uses its native promise-pipelining surface for the
reference row.

The application has the same shape in every language but is not
byte-for-byte identical. The richer cross-language Tasks application provides a
separate behavioral check through `zig build demo-tasks`.

## Warmup and collection

Deno, Python, Racket, and Goblins run as many as 500 warmup units and request a
collection before each measured latency, throughput, or local-turn window.
Collections caused during the window remain in the result.

Zig and Rust report a warmup count of zero. The report records each row's
warmup count rather than assuming the runtimes have identical startup or memory
behavior.

Before cold-start sampling, the orchestrator tries to compile the Racket client
scripts to bytecode. This keeps source compilation from dominating only the
Racket-binding row when compilation succeeds. The step is best-effort; if it
fails, the run continues and the source-load cost remains in the measurement.

## Metrics

### Latency and throughput

Latency reports p50, p99, p999, and mean milliseconds for sequential units.
JIT and garbage-collection pauses inside the window remain visible.

Throughput reports completed pipelined units per second. It measures steady
state on one connection, not concurrent-client saturation.

### Session setup and memory

Each client opens throwaway connections before the baseline sample, then holds
the measured connections open for the loaded sample. Setup time includes
connecting and fetching the root capability.

On Linux, the orchestrator reads the client process's `VmRSS` from `/proc`.
It keeps the minimum of several baseline and loaded samples, subtracts them, and
divides by the connection count. If RSS cannot be read, the report leaves the
field blank.

This is process-level resident memory. Runtime heap growth, garbage-collector
granularity, and pages faulted in during earlier work can dominate a small
connection delta. Use it for order-of-magnitude tracking within one runtime
class, not as bytes allocated per session or as a cross-language ranking.

### Local turn

Each client runs a counter actor through two paths:

- `in_lang` uses that binding's normal in-process actor dispatch.
- `via_host` publishes the same behavior across a loopback pair inside the
  client process, forcing the call through the C host, codec, and marshaling
  path in both directions.

Both paths run sequential send-and-settle units and report mean and p99
nanoseconds per turn. Goblins has no glowcap C host, so its `via_host` fields
are empty.

`via_host` is the existing loopback C-host path, included to inform the question
of routing local actors through a Zig vat. A real local Zig path is not
implemented and may differ in either direction. The measurement does not
establish an upper bound or predict its final cost.

### Cold start

Cold start measures process spawn through one completed task-board unit:
connect, fetch the root, then create, assign, complete, and inspect a task. It
is reported separately from steady-state latency because interpreted, JIT, and
ahead-of-time runtimes have fundamentally different startup work.

## Limits

- Each row includes its runtime, binding, application implementation, and
  garbage collector. A gap cannot be assigned to the language or wire alone.
- The benchmark uses one loopback host and does not model network loss, routing,
  or field latency.
- Throughput uses one pipelined connection; it does not measure many-client
  contention.
- RSS is too coarse to compare small per-connection costs across different
  runtime heaps.
- Optional clients are skipped when unavailable. A Zig-only smoke run is still
  valid, but it is not a comparison.
- The Goblins row is a Goblins peer dialing the glowcap host, not Racket using
  glowcap's binding.

These limits are why reports are dated artifacts rather than permanent project
claims.
