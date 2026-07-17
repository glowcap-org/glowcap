---
id: ADR-0073
status: accepted
date: 2026-07-11
tags: [performance, gates, bench]
decision: "Wall-clock cost is gated as a ReleaseFast order-of-magnitude tripwire (perf-check, a member of check): absolute min-of-batch ceilings on the two hot-path turns plus a dimensionless linearity ratio on the gc-answers storm, with the ceilings owned by docs/ladder.md rung 2."
supersedes: []
superseded_by: []
---

# ADR-0073 The Wall-Clock Tripwire Gate

## Context

ADR-0045 gates the byte side of the performance contract: exact allocation
counts, a `comptime` ceiling on `@sizeOf(engine.Peer)`, and the warmed
2 KiB-per-connection footprint. Wall-clock time was only printed: the benches
ran in Debug under `check` with a `mode=` stamp and the instruction to "compare
relative regressions" by eye. A measured number no gate defends is a wish, and
the regression classes the allocation gates are blind to (a copy inside a loop,
a Debug-only path leaking into hot code, a reverted inverse map: all
allocation-free) had no mechanical check at all. This engages the First
Principle "Performance is a public contract": every cost is forbidden, named,
or measured, and a measured cost needs a gate to stay measured.

The obstacle was honesty about hardware. CI runners and dev machines vary by
several times in single-thread speed, so a threshold tight enough to catch a
20% drift flakes somewhere, and a gate that flakes is worse than a print.

## Decision

`zig build perf-check`, a member of `check`, runs the two hot-path benches in
ReleaseFast and holds three ceilings:

- one warm inbound dispatch turn (`bench/dispatch_scaling_bench.zig --gate`),
  gated on the **minimum of five batch means**: the right estimator for
  CPU-bound work, since contention inflates some batches but almost never all
  of them: against an absolute ceiling roughly an order of magnitude over the
  measured figure;
- one answered outbound send (`bench/outbound_bench.zig --gate`), same
  estimator, same headroom;
- the `op:gc-answers` release storm's linearity, gated as the **ratio** of
  ns/answer at Q=8,000 to Q=1,000. The ratio is the same code at two sizes, so
  machine speed cancels out of it entirely; it mechanically defends the
  answer-to-resolver inverse map (`session.OutboundResolverAnswers`), which a
  reintroduced per-position scan would show as roughly Q-proportional growth.

The ceilings are `pub const`s at the top of the two bench files;
`docs/ladder.md` rung 2 owns the numbers, and a ceiling moves there and in the
constant together. Each gate arm refuses to run outside ReleaseFast, so a
mis-wired Debug run fails loud instead of gating noise. The gate runs replace
those two benches' former Debug `--smoke` runs under `check`: a ReleaseFast
gate run proves "still runs" strictly stronger.

Because optimize mode is per-module, the gate executables import a dedicated
ReleaseFast library graph (`fast_lib_mod` in `build.zig`), never the
`-Doptimize` graph. The same graph now backs the `bench-langs` host and Zig
client, whose "pinned to ReleaseFast" claim was previously false for the
library code they imported.

## Scope (what this does not decide)

The tripwire catches structural regressions, not drift: a 20% slowdown passes.
Precision measurement stays with the printed benches and `bench-site-report`
on pinned hardware. Cold-cache dispatch scaling at large N (dominated by cache
size, legitimately machine-shaped), codec micro-numbers (a strict subset of
both gated paths), and the iroh path (needs cargo) stay ungated. No stored
per-machine baselines: a gate passes by its exit code from a fresh checkout.

## Alternatives Considered

- **Self-calibrated ratio against a reference op** (turn cost in units of one
  boundary clone): cancels contention but not microarchitecture: the ratio
  itself varies 2–3× across CPU families: and a regression in the reference
  op masks the gated one. Rejected for the absolute gates; the ratio form is
  kept exactly where numerator and denominator are the same code (the storm).
- **Stored per-machine baseline**: state; makes the first run undefined and
  the Nth depend on machine history. Rejected.
- **Hardware perf counters**: stable but need `CAP_PERFMON`, absent in most CI
  containers. Rejected; the escalation path if the tripwire ever proves noisy.
- **Sibling step outside `check`**: rejected because the ReleaseFast graph
  cost was already owed by the `bench-langs` honesty fix, the workload is
  hermetic (in-process peers, no ports), and a gate nobody runs is a print
  with extra steps.

## Consequences

`check` compiles one ReleaseFast library graph and spends ~2 s running the
gates. A red `perf_gate` line names the path, the measured figure, and the
ceiling in machine-neutral terms. An exotically slow environment (emulation)
can trip an absolute ceiling; each is one constant, and the devcontainer is
the canonical environment. `bench-langs` Zig rows now genuinely measure
ReleaseFast pancake, so previously published figures may shift at the next
`bench-site-report` regeneration.
