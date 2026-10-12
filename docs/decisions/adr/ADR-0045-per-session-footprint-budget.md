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
sessions. The peer-scaling bench stands up thousands of `engine.Peer`s
in-process and extrapolates to 500k, but nothing gated the result. A regression
that doubled `@sizeOf(engine.Peer)` or grew the warmed session heap passed
`zig build check`, because the bench only reported. The sans-io core cannot
deliver 500k by itself, but per-session bloat can make 500k impossible, so
bounding that state is the core's obligation and needs a gate.

## Decision

The budget has two halves.

The compiler holds the inline half. `engine.Peer` declares
`peer_session_struct_budget_bytes = 1024` and a `comptime` block that fails the
build with the measured size if `@sizeOf(Peer)` ever exceeds it. This is a
ceiling, not an equality, so it holds on every target (wasm32's narrower
pointers only make `Peer` smaller), and it cannot be skipped, because it fails
when `engine` compiles.

A test holds the runtime half. `test/engine/footprint_budget_test.zig` stands up
a sample of peers under a live-bytes-tracking allocator, warms each with one
`op:deliver` turn to a live export, divides the steady heap by the count, adds
the inline struct size, and fails if the warmed total exceeds 2048 bytes per
connection. 2 KiB times 500_000 is under 1 GiB of protocol-core state. The
instrumented allocators both budget tests share live in
`test/support/alloc_metrics.zig`.

The bench is the report, and the tests are the gate.
`zig build bench-peer-scaling` measures the live numbers and writes the markdown
and SVG report. `zig build check` runs the same executable in `--smoke` mode,
which uses a tiny sample and writes no report artifact, so the gate proves the
bench still runs without report work.

## Scope (what this does not decide)

This budgets the protocol core measured in-process. It does not budget the
transport. A live connection on the completion loop also holds a fixed read
buffer that dominates the core state, and a real 500k-connection run's accept
throughput, syscalls per turn, and resident-set growth are not measured here.
That live-socket measurement is step 5 of the ladder. This ADR defends the
core's part of the budget, not the whole-system number.

## Alternatives Considered

- **Leave the bench as a report.** Rejected: a number no gate defends drifts the
  first time someone adds a session field.
- **Gate only at runtime, in the test.** Rejected: the struct-size half is
  known at `comptime`, and a compile-time ceiling catches the regression at the
  edit and on every target, including the wasm core build.
- **Put the budget number in an adapter or the bench.** Rejected: the
  per-session footprint is the core's obligation, so the core owns the ceiling.

## Consequences

`src/ocapn/engine/mod.zig` exports `peer_session_struct_budget_bytes` and fails
to compile if `Peer` outgrows it. `test/engine/footprint_budget_test.zig` and
the shared `test/support/alloc_metrics.zig` hold the runtime half. `build.zig`
runs the peer-scaling bench in `--smoke` mode under `check`. The ladder's step 2
("The Performance Contract, In Numbers") and the vision's "The Number" section
are the living-state surfaces that quote these budgets. Changing a budget
changes them in the same diff.

## Notes

Relates to ADR-0041 and ADR-0042, which bound the transport-side per-connection
memory the live-socket measurement on step 5 will weigh against this core
budget.
