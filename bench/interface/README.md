---
type: static
description: Paired raw and generated Rust interface costs and their measurement limits.
sources:
  - resource: /bench/interface/
  - resource: /tools/build/interface_bench.zig
  - resource: /tools/interface/
---

# Interface costs

Compare generated Rust calls with equivalent handwritten calls over loopback
TCP. Both use the same actor and current-thread runtime, with Syrup and CapTP
1.0. Setup, fetching, warmup and teardown stay outside timed operations.

```sh
.agents/skills/work/bin/glowcap-dev zig build bench-interface-diagnostics -Doptimize=ReleaseFast
.agents/skills/work/bin/glowcap-dev zig build bench-interface-generation -Doptimize=ReleaseFast
.agents/skills/work/bin/glowcap-dev zig build bench-interface-builds -Doptimize=ReleaseFast -- --pairs=3
.agents/skills/work/bin/glowcap-dev zig build bench-interface -Doptimize=ReleaseFast -- --mode=latency --samples=100 --pairs=3 --warmup=20
.agents/skills/work/bin/glowcap-dev zig build profile-interface -Doptimize=ReleaseFast -Dcpu=baseline
```

Use a quiet host for latency and build-time claims, following the
[benchmark methodology](../README.md). Raw and generated windows alternate
order between pairs. Keep each pair's values beside any aggregate.
`interface-bench-smoke`, part of `runtime-check`, checks effects, traffic,
output and both build selections without a timing threshold.

## Timed operations

| Row | Measured work | Actor checks |
| --- | --- | --- |
| Ordinary | Construct input, send positional call, await and move decoded text | One call with the expected input and output |
| Preparation | Snapshot input, query sequence, validate and retain mutation arguments | One query and no mutation |
| Submission | Send retained mutation, await and decode capability | One submission and one effect |
| Replay | Send the same retained mutation, await and decode capability | One submission and no additional effect |

Preparation runs before submission and replay timing. Replay also submits once
before timing. Both clients retain the target, sequence, input string and
argument vector. The actor keeps only the latest receipt, so its history does
not grow with the sample count. These calls do not measure durable Loam
commits or recovery.

## Allocations and messages

Timing uses the normal allocators. A diagnostic build installs a Rust meter
and another meter shared by both Host contexts. The latter calls `System`
directly, so Rust does not count those allocations again. Transport allocations
outside those contexts remain outside that meter's scope.

Rows report successful allocation requests, requested bytes and the outstanding
byte change while holding the result. Requested bytes are demand, not peak
memory or copied bytes. The timing sample vector is reserved beforehand.

The message pass forwards TCP through an observer that counts every outer
Syrup operation by direction. The Host trace skips control frames.
The observer watches the operation, result and request release, and teardown
through both EOFs. This includes deferred control traffic and queued frames
sent after their receiver closes during cancellation.

Forwarding errors fail until teardown starts. Frame lengths can differ because
independently minted names have different encoded lengths. The counter
`codec_frame_bytes` excludes TCP's decimal length prefix. The observer runs
in neither timing nor allocation passes.

## Copies we can count

Both ordinary paths copy the borrowed input into one string and move the reply
string. Both preparation paths copy the input once before querying the
sequence, then move it into one retained vector with an owned operation string.
Submission and replay borrow that vector and add no wrapper payload snapshot.
The generated path adds zero wrapper payload copies over raw calls.

The report records the source hashes behind this comparison. It does not count
all binding, codec, transport or system copies. Allocation demand and frame
lengths cannot provide that total. The profile attributes instructions to
visible copy callers, but inlining prevents a complete copied-byte count.

## Builds and generation

The build comparison selects only the raw or generated client. Raw builds do
not import generated modules. Both still compile the actor, TCP pair, runtime,
timers, assertions and profile bridge, with identical dependencies and settings.
After warming both selections, each sample changes an unused compiler flag
for the top crate, forcing fresh compilation and linking. A sample fails if
Cargo compiles another crate.

Build times include Cargo bookkeeping and the deadline launcher. They exclude
full clean builds. Generation runs the built fixture verifier after warmup,
generates the selected corpus and compares it with checked-in files.
Compilation stays outside generation timing. Verification reads remain inside.

The RSS value from `wait4` bounds the generator's peak and includes inherited
memory before execution. It does not isolate the generator's resident memory.
JSON reports under `zig-out/bench-reports/` record revision, dirty state,
toolchains, container pin digest, CPU, kernel, memory and CPU affinity.
The source inventory separates compiler code, embedded tests, qualification
sources, generated outputs and benchmark code. Helpers outside test blocks
count as implementation. Generated output gives no credit against compiler
maintenance cost.
