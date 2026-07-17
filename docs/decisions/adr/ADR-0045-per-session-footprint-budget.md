---
id: ADR-0045
status: accepted
date: 2026-06-11
tags: [performance, memory, gates, engine, scaling]
decision: "The 500k-connection destination is enforced as a per-session memory budget gated by the build: engine.Peer carries a comptime ceiling on its own struct size (one kilobyte), test/engine/footprint_budget_test.zig holds the warmed total (struct plus session heap) at or under two kilobytes per connection, and the peer-scaling bench runs in --smoke mode under check while the full report stays a separate step."
supersedes: []
superseded_by: []
---

# ADR-0045 Per-session footprint budget

## Context

The vision names a number: one node holds five hundred thousand live CapTP
sessions. The repository measured the per-connection footprint: the
peer-scaling bench stands up thousands of `engine.Peer`s in-process and
extrapolates to 500k: but nothing _gated_ it. A regression that doubled
`@sizeOf(engine.Peer)` or grew the warmed session heap passed `zig build check`
silently, because the bench only reported. This sits on the First Principle that
performance is a public contract: a wire-path allocation or a per-session byte
is forbidden, named, or measured. A measured-but-ungated number is none of those
once it can drift unnoticed. The sans-io core cannot deliver 500k by itself, but
it can make 500k impossible by letting per-session state bloat, so bounding that
state is the core's obligation, and an obligation without a gate is a wish.

## Decision

The budget is two halves, each held by the strongest organ that fits.

The inline half is held by the compiler. `engine.Peer` declares
`peer_session_struct_budget_bytes = 1024` and a `comptime` block that fails the
build with the measured size if `@sizeOf(Peer)` ever exceeds it. This is a
ceiling, not an equality, so it holds on every target: wasm32's narrower
pointers only make `Peer` smaller: and it cannot be skipped, because it fails
when `engine` itself compiles. The core asserting its own size is the core
holding its own contract, not adapter policy reaching down.

The runtime half is held by a test. `test/engine/footprint_budget_test.zig`
stands up a sample of peers under a live-bytes-tracking allocator, warms each
with one `op:deliver` turn to a live export, divides the steady heap by the
count, adds the inline struct size, and fails if the warmed total exceeds 2048
bytes per connection. The committed arithmetic is honest: 2 KiB times 500_000 is
under 1 GiB of protocol-core state. The instrumented allocators both budget
tests share now live in `test/support/alloc_metrics.zig`.

The bench is the report, not the gate. `zig build bench-peer-scaling` measures
the live numbers and writes the markdown and SVG report; `zig build check` runs
the same executable in `--smoke` mode, which uses a tiny sample and writes no
report artifact, so the gate proves the bench still runs without doing report
work as a side effect. The `--smoke` flag the bench's own documentation had
claimed but never parsed is now real and wired.

## Scope (what this does not decide)

This budgets the protocol core measured in-process. It does not budget the
transport. A live connection on the completion loop also holds a fixed read
buffer that dominates the core state, and a real 500k-connection run's accept
throughput, syscalls per turn, and resident-set growth are not measured here.
That live-socket measurement is rung 5 of the ladder, where the budget meets a
socket. No surface claims 500k as an achievement on the strength of this ADR;
this ADR defends the core's part of the budget, not the whole-system number.

## Alternatives Considered

- **Leave the bench as a report.** Rejected: a measured number that no gate
  defends drifts the first time someone adds a session field without weighing
  it, which is exactly the failure the budget exists to prevent.
- **Gate only at runtime, in the test.** Rejected: the struct-size half is
  `comptime`-knowable, and a compile-time ceiling is sharper than a test: it
  catches the regression at the point of the edit and on every target, including
  the wasm core build.
- **Put the budget number in an adapter or the bench.** Rejected: the
  per-session footprint is the core's obligation, so the core owns the ceiling;
  the adapter inherits a substrate that already fits, rather than discovering
  the cost later.

## Consequences

`src/ocapn/engine/mod.zig` now exports `peer_session_struct_budget_bytes` and
fails to compile if `Peer` outgrows it. `test/engine/footprint_budget_test.zig`
and the shared `test/support/alloc_metrics.zig` are new; `alloc_budget_test.zig`
moved its counting allocator into that shared module. `build.zig` runs the
peer-scaling bench in `--smoke` mode under `check` instead of the full
report-writing run. The ladder's rung 2 ("The Performance Contract, In Numbers")
and the vision's "The Number" section are the living-state surfaces that quote
these budgets; changing a budget changes them in the same diff.

## Notes

Relates to ADR-0041 and ADR-0042, which bound the transport-side per-connection
memory the live-socket measurement on rung 5 will weigh against this core
budget.
