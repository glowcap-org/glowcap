---
type: living
description: Measured allocation and traversal counts for Rooms host routes, projection and admission.
sources:
  - resource: /bench/host_locator_bench.zig
  - resource: /bench/rooms/
  - resource: /apps/rooms/rust/
---

# Rooms session cost measurements

Measured on 2026-10-09, using the pinned
development container. Most tables are allocation and traversal counts, not network latency or
user-visible response time. The work admission section reports timings.

## Host route ownership

`zig build bench-host-locator` measures 1,024 warmed operations per case.
Setup and catalog growth are outside the window. The configured profile is
CapTP next with Cap'n Proto and default features. Four carried route hints
exercise heap-backed hello scratch. Both select and retain produce these counts:

| Operation | Allocations before → after | Requested bytes before → after |
| --- | ---: | ---: |
| Replace, no carried hints | 18 → 9 | 490 → 245 |
| Replace, four carried hints | 35 → 18 | 1,176 → 728 |
| Repeated accept fallback | 9 → 0 | 245 → 0 |

The Node owns the sole durable locator snapshot. Host completion borrows input
and caller-owned hint scratch until that snapshot is retained. The public owned
preparation API returns independent storage. Driver budgets cover both
replacement verbs, scratch overflow, aliased inputs, every allocation refusal
and owned preparation after Host teardown.

## Membership reconciliation

The production membership scenario counts actual `snapshot` invocations through
the session content endpoint. An unchanged-standing draft gesture requires
three requests before and two afterward: one for the gesture, one for the worker,
and no separate standing read. The standing worker consumes the wake snapshot.
Conflict and settlement require fresh reads. Uncertain commands keep their
original ownership. Inheritance, empty overrides, source pause/resume and unrelated
changes run through that same scenario.

## Browser projection

`zig build bench-rooms-projection` counts visits through the production UI
projection. Each conversation displays 64 lines and retains custody of 32.
The benchmark also checks exact held and unheld display state.

| Conversations | Conversation visits before → after | Line ID reads before → after |
| ---: | ---: | ---: |
| 16 | 288 → 16 | 24,832 → 512 |
| 64 | 4,224 → 64 | 99,328 → 2,048 |
| 256 | 66,048 → 256 | 397,312 → 8,192 |

One temporary map borrows presented conversations through the projection pass.
One scalar set indexes each conversation's held line IDs. Archive-share state
uses a temporary lookup at the same seam. These indexes copy no messages or
capabilities and retain no workspace snapshot between passes. The cost regression
fails against the baseline's repeated searches.

`RoomsManagedActivityReader::read` classifies incoming custody from the JavaScript
event it already decoded. This removes a second full Rust JSON tree per incoming
event. Production browser journeys exercise both line routes and other authority
handles. Outgoing reference collection returns its final vector directly. This is a
simpler ownership expression and saves no allocation.

## Reproduce

Run commands through `.agents/skills/work/bin/glowcap-dev`:

```sh
zig build bench-host-locator bench-rooms-projection
zig build test -Dtest-filter='core host locator'
zig build rooms-rust-test rooms-server-test rooms-managed-rooms-browser-test
```

The [memory ledger](../../.agents/skills/memory-ledger/SKILL.md) inventories the
remaining owners.

## Work admission

Measured on 2026-10-12, in the same pinned development
container. Each row reports three sequential samples with no concurrent build
or proof launched by this task. Rust tests use Cargo's test profile and fresh
storage. These small samples describe this workload, not a production latency
guarantee or statistical equivalence.

| Workload | Baseline median (range), µs | Admission median (range), µs |
| --- | ---: | ---: |
| TCP directory, 64 posts to eight recipients | 2,200 (2,167–2,345) | 2,317 (2,282–2,317) |
| Local shared session, four collaborators, 32 sequential commands | 35,221 (32,762–88,635) | 35,404 (35,366–48,489) |

- The TCP window covers acknowledged posts, including directory fan-out.
- The shared window covers snapshot, command admission, persistence, private
  forwarding and terminal observation. Each collaborator is warmed once before
  measurement.
- A real target receives every command exactly once, with no external network
  hop. The baseline uses the identical scenario with the startup
  configuration call omitted.
- The TCP medians differ by about 5%, within overlapping sample ranges. The
  shared medians differ by less than 1%. Neither result isolates admission CPU
  cost from scheduling and storage.

`bench-rooms-admission` isolates portable policy cost in its optimized example:
one admitted subject, message count and 32 bytes charged atomically, 100,000
warmed operations. The measured check takes 72–88 ns admitted and 43–57 ns
refused, with zero steady allocations. The borrowed-loop baseline takes 1 ns.
Filling 8,192 rows with 33-byte keys requests 5,336,760 tree bytes cumulatively.
That measures allocation requests, not RSS. Configured row caps and fixed keys
bound retained policy memory.

Acceptance also exercised 128 actual peers and 381 posts. An unread
application inbox reached its bounded overflow while the healthy reader kept
receiving. Cleanup completed within the scenario's 25-second deadline. This
tests an application slow reader. Host transport-pressure proofs own socket
flow-control evidence. A separate 30-second proved-identity reconnect scenario
admitted eight starts, refused 23, joined six times and delivered 31 unrelated
healthy-peer posts.

Reproduce the owning scenarios with Cargo through `glowcap-dev`:

```sh
zig build bench-rooms-admission
cargo test --manifest-path apps/rooms/rust/Cargo.toml -p rooms-services --features processes --lib ordinary_crowded_room_cost_sample -- --nocapture
cargo test --manifest-path apps/rooms/rust/Cargo.toml -p rooms-contract-proofs --lib ordinary_shared_session_cost_sample -- --ignored --nocapture
```

The direct Cargo commands need `GLOWCAP_LIB_DIR` and `LD_LIBRARY_PATH` pointing
to this checkout's built `zig-out/lib`. The allocation sample is part of the
owning Rooms gate. Long pressure scenarios are ignored in the ordinary unit run and run
separately under their own deadlines.
