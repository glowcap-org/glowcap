---
type: living
description: What the benchmarks measure and the runs recorded so far.
sources:
  - resource: /bench/
---

# Benchmarks

The benchmarks measure what glowcap costs. They never decide behavior, which
is the tests' job. [Build steps](../docs/build-steps.md) lists every `bench-*`
step. Absolute figures come from `-Doptimize=ReleaseFast` runs, and a smoke
run only proves a bench still runs.

Record the date, source revision, hardware
model, CPU, RAM, kernel, filesystem and storage device with latency results.
Link to that environment when several studies share it. Measure
code that matches `dev`, on a host with nothing else running: another build on
the same cores moves every figure.

## Against a base revision

`zig build bench-ab -- --base=<rev> <bench-step> [args]` runs one bench
alternately on the archived base revision and on this tree, ReleaseFast on
both sides, three pairs by default (`--pairs=N`), and prints each row of the
bench's `key=number` output with the median of each side, their ratio, and
every pair's values. Both sides see the same minutes of the same host, so a
drift during the run lands on both. Read the ratio beside the pairs: a ratio
inside the spread of the pairs is noise, and a ratio outside it is the claim.
The base is extracted once under `zig-out/scratch/ab/<rev>` and reused.

## Profiles

A `profile-<bench>` step runs the bench under callgrind and writes
`zig-out/bench-reports/<bench>-profile.md`: for each phase the bench marks,
the self cost per source file and per function, ranked, and the callers of the
leaf functions at the top. Read it this way:

- Instructions retired (Ir) is the unit. It does not move with load, clock,
  or cache state, so two runs of one build repeat it exactly and a before and
  after diff of Ir on the same phase is evidence on its own, with no quiet
  machine needed.
- Self cost is the ranking. The build is ReleaseFast, so inclusive cost and
  call trees follow inlining and mislead. A function high on the list is where
  the instructions execute, and the bench's own source says who asked.
- A leaf such as `memcpy` or a decoder runs for many callers, and its cost at
  each call site is exact. The callers table under it says whose copy or
  decode it was, with the calls and the instructions the leaf ran for each.
- Each marked phase is one part, collected on its own. Setup and teardown
  between phases run uninstrumented and count nothing.
- A profile ranks cost inside one run of the bench. The bench's ReleaseFast
  wall-clock figure is still the claim a change makes, so profile first, change
  the top of the list, then measure.

A bench marks a phase with `bench/support/profile.zig`: `begin()` before the
timed loop and `end("<phase>")` after it. The marks compile to nothing in the
ordinary bench build.

## Results

The [performance report](https://glowcap.org/performance/) and
[comparison report](https://glowcap.org/performance/compared/) contain the
generated figures, with their source revision and run environment.
`zig build bench-site-report` regenerates both from live runs. Keep numerical
results in those reports instead of copying them into this index.

## Floors

`zig build bench-floors` times each primitive alone: signing, verification,
Noise handshakes and records, frame copies, thread wakeups, and loopback
round trips. Compare a product path with the floors it pays. Protocol work
without a primitive floor answers to the `perf-check` ceilings.

Pin both sides of a round trip to one core to measure shared-core scheduling,
or to separate cores to include cross-core wake latency. A busy-poll pair
needs a core per runtime. Record the pinning beside each result, and compare
mean primitive costs with product medians only when that distinction is explicit.

`profile-roundtrip` attributes each side's work under callgrind. Compare the
server separately from the caller, and keep raw profiles with the report.
Grouping instructions by concern requires the same run for every row.

## Against Cap'n Proto

`zig build bench-capnp` times two calls in the C++ reference library and the
`capnp-rpc` Rust crate over loopback TCP. The [recipe](capnp/README.md)
and [schema](capnp/echo.capnp) define the comparison:

- `greet("world")` answers a fixed greeting without inspecting the argument.
- `report(source, tags, samples, at)` reads an application batch and answers
  its count and sum.

The glowcap comparison uses `bench-iroh --transport=tcp` with both Syrup
and Cap'n Proto codecs. A growth sweep uses `--row=report --readings=N` and
an explicit `--frame-cap` large enough for both encodings. The frame limit
also bounds the logical value tree before encoding.

Each harness builds and sends its request and reads the reply inside the
timed window, then checks the answer after timing stops. Use the same call
count, warmup, percentile, and pinning across harnesses. Record the C++
library's build settings separately from the benchmark's optimization flags.
These round trips include allocation, transport, scheduling, and handler
work, so their differences do not isolate codec throughput.

## Against Spritely Goblins

`zig build bench-goblins` runs one Racket application on two backends,
[Spritely Goblins](https://spritely.institute/goblins/) and glowcap's Racket
binding over the C ABI. Separate client and server processes run on one
machine over loopback TCP, with one call in flight. Both sides use Racket.
The echo suite measures a single call. The registry, purse, and task-board
suites measure operations spanning several calls. Keep variation across
repeated runs beside every comparison.

## Live sessions

`zig build bench-peer-scaling -- --live` measures real loopback sockets at
increasing connection counts. The server and load generator are separate
processes. Each server shard is a `HostRuntime` serving TCP through a
completion resident ([ADR-0018](../docs/decisions/adr/ADR-0018-one-host-io-runtime.md)).
Every client signs its session and fetches a published capability before
the barrier opens. All sessions stay open while RSS is sampled.

The connections use cleartext TCP with signed handshakes. Run in a separate
user and network namespace to keep host connection-tracking rules from
binding the experiment, and raise the descriptor limit for both processes.
This recipe requests a capacity run. Its requested count is not a measured
result:

```sh
unshare -Urn sh -eu -c '
ulimit -n 524288
ip link set lo up
exec zig build -Doptimize=ReleaseFast bench-peer-scaling -- --live --live-max=500000
'
```

Record baseline and loaded RSS for each process, completed session count,
barrier duration, backend, and machine configuration. Same-machine capacity
and amortized handshake time do not measure WAN latency. The generated
[live-session report](https://glowcap.org/performance/#live-sessions) contains
completed capacity runs and separate session-opening timings.
