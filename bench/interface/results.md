---
type: living
description: Paired Rust interface cost measurements from November 3, 2026.
sources:
  - resource: /bench/interface/
  - resource: /tools/interface/
  - resource: /test/interface/rust/pair.rs
---

# Interface costs, 2026-11-03

Calls and consumer builds were measured at clean revision
`7f05db9a2c1f0cf6e62274d5eed729d7d6b24762`, on parent `cbeecf11`.
Diagnostics, generation and profiling used reporting-only child `689a093d`.
The measured Rust and glowcap code is identical between those revisions.
The [commands and measurement definitions](README.md) reproduce the runs.

## Environment

| Item | Recorded value |
| --- | --- |
| CPU | aarch64, ARM implementer `0x41`, architecture `8`, part `0xd87`, variant `0x0`, revision `1` |
| CPU affinity | CPU 10 for both endpoints and all measured consumer builds |
| Memory | `MemTotal: 127598768 kB` |
| Kernel | `7.0.0-1019-nvidia` |
| Storage | `SAMSUNG MZALC4T0HBL1-00B07`, non-rotating, filesystem reported as `ext2/ext3` |
| Compilers | Zig `0.17.0`, rustc `1.99.0 (b940084d7 2026-09-28)` |
| Build settings | Zig ReleaseFast, Rust release with debug info level 1 |
| Runtime | One current-thread Tokio runtime, loopback TCP, Syrup, CapTP 1.0 |

Container pins SHA-256:
`f785a7e74928497bf1326fca0b04bb2d9b2c7341f10c0c4dfa7ed5fc8bc746af`.
The committed Cargo lock SHA-256 is
`fff6560095a951a1f1808289bec047dde808bb23f8afe8fa249468b100505d58`.
Storage metadata was observed through the worktree's device, without recording
its identifier. Other local builds were held during latency and build windows.

## Call latency

Each window contains 500 sequential operations after 100 warmups, with a
15-byte input. Cells show **p50, p99, mean in microseconds**.
Pairs 1 and 3 ran raw first. Pair 2 ran generated first.
Setup, preparation for submission/replay, result validation and teardown are
outside each timed operation. Returned values cross a compiler barrier before
timing stops.

| Operation | Client | Pair 1 | Pair 2 | Pair 3 |
| --- | --- | --- | --- | --- |
| Ordinary | raw | 35.456, 47.296, 36.006 | 35.104, 46.336, 35.710 | 36.049, 50.608, 37.130 |
| Ordinary | generated | 35.440, 47.920, 36.105 | 35.472, 46.528, 36.129 | 35.761, 50.017, 36.510 |
| Preparation | raw | 33.936, 46.544, 34.562 | 33.729, 48.160, 34.424 | 34.048, 47.888, 34.801 |
| Preparation | generated | 34.320, 44.704, 34.936 | 34.528, 50.769, 35.425 | 34.448, 46.768, 35.265 |
| Submission | raw | 39.953, 49.280, 40.519 | 39.776, 50.240, 40.277 | 40.080, 50.545, 40.555 |
| Submission | generated | 40.000, 50.496, 40.651 | 40.368, 51.744, 40.809 | 40.832, 51.856, 41.467 |
| Replay | raw | 43.009, 50.592, 43.363 | 43.649, 54.240, 44.161 | 43.504, 53.776, 44.164 |
| Replay | generated | 43.808, 55.761, 44.756 | 43.696, 53.216, 44.154 | 43.408, 53.648, 43.934 |

These values describe the four measured operations. They do not establish
end-to-end durable mutation latency or a general performance improvement.

## Consumer builds and generation

Fresh compilation and linking of the selected top crate, in seconds:

| Client | Pair 1 | Pair 2 | Pair 3 |
| --- | ---: | ---: | ---: |
| raw | 6.469264 | 6.514537 | 6.514507 |
| generated | 6.563518 | 6.618080 | 6.615119 |

Dependencies were warm and locked. Only the top crate recompiled in every
sample. Times include Cargo bookkeeping and the deadline launcher.
Raw builds exclude both generated modules, as checked in Cargo's dependency
file. A separate probe poisoned both modules: raw-only compilation succeeded,
and generated-only compilation failed. Both files were restored exactly.

Warm generation plus fixture verification, in milliseconds:

1.343098, 1.284026, 1.285881, 1.291418, 1.296953, 1.286122, 1.281753.

Every process reported the same peak RSS upper bound: 20,328,448 bytes
(19.39 MiB). It includes inherited pre-exec memory. The maximum
time and this memory bound are below the corpus limits in the interface plan.

## Allocations and messages

Allocation counts cover one operation while holding its result. Rust and both
Host contexts use separate meters. Host requests use the diagnostic allocation
policy. Wire counts instead cover the operation, request/result release and
session teardown through EOF.

Counts match between raw and generated clients in every row:

| Operation | Rust allocations | Rust requested bytes | Rust live-byte change | Host allocations | Outbound frames | Logical calls | New effects |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Ordinary | 11 | 2700 | 15 | 13 | 6 | 1 | 0 |
| Preparation | 7 | 2442 | 282 | 11 | 6 | 1 | 0 |
| Submission | 12 | 2865 | 64 | 14 | 6 | 1 | 1 |
| Replay | 11 | 2850 | 64 | 18 | 7 | 1 | 0 |

Byte observations below give **raw / generated** values.

| Operation | Host requested bytes | Host live-byte change | Codec frame bytes |
| --- | ---: | ---: | ---: |
| Ordinary | 3723 / 3723 | 0 / 0 | 349 / 349 |
| Preparation | 3598 / 3596 | 0 / 0 | 338 / 333 |
| Submission | 3872 / 3872 | 0 / 0 | 391 / 389 |
| Replay | 4532 / 4526 | 0 / 0 | 429 / 435 |

Direction-and-operation histograms also match, including GC and abort frames.
Removing one generated GC category made parity fail with equal frame totals.
Host requested bytes and codec-frame lengths vary with minted names, so they
are descriptive values, not equality assertions.
Preparation retains 282 Rust bytes in both paths. The one-operation profile
records 80,615 and 80,858 instructions for raw and generated preparation.

## Source review and size

At the measured revision, both ordinary wrappers make one input-string copy
and move the reply string. Both preparation paths copy the 15-byte input once,
then move it into one retained argument vector with a 3-byte operation string.
Submission and replay borrow that vector. The generated wrappers add zero
payload copies relative to those raw paths.
The [raw workflow](src/workflow.rs),
[creation template](../../tools/interface/templates/creation.rs) and
[retained request template](../../tools/interface/templates/receipt.rs)
contain those string and vector operations.

Those are manually reviewed source counts for this revision. Total copied
bytes across bindings, codecs and transport are not instrumented.
The generated calls retain no schema graph or method registry.

| Nonblank source | Lines |
| --- | ---: |
| Shared reader, checked model, calls and literals | 367 |
| Zig/Rust emitters and Rust templates | 299 |
| TypeScript emitter and template | 70 |
| Generation driver and independent expectations | 118 |
| Embedded Zig tests | 147 |
| Handwritten qualification, including the three Goblins clients | 1,309 |
| Generated output, with no compiler-size credit | 479 |
| Benchmark infrastructure at reporting revision `689a093d` | 1,387 |

The shared compiler, emitters and narrow TypeScript probe remain below their
source ceilings. These results cover this corpus, profile and text workflow.
They do not qualify another codec, a larger interface corpus or durable engines.
