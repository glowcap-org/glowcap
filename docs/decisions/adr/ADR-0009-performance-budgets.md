---
id: ADR-0009
status: accepted
date: 2026-10-19
tags: ["performance", "memory", "gates", "engine", "scaling", "bench"]
decision: "Types own compile-time size ceilings, and allocation tests hold the warmed retained state that a struct size cannot describe."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0009 Performance budgets

## Context

A measured footprint can regress silently when a field or allocation is added. Precise timings also vary with hardware and contention.

## Decision

Types own compile-time size ceilings, and allocation tests hold the warmed retained state that a struct size cannot describe. Transport and application costs remain separately attributed.

ReleaseFast timing checks are broad tripwires for structural regressions. They use fresh-run absolute ceilings where practical and a same-code growth ratio for GC scaling. Detailed reports remain reproducible measurements with a named environment.

## Alternatives and consequences

A report alone cannot prevent drift. A runtime-only size check misses a fact the compiler knows. A stored machine baseline leaves a cold checkout undefined and makes results depend on local history. Calibrating against a different operation can hide a regression in the reference itself.

A passing tripwire does not establish that a small slowdown is absent. Emulation and unusually slow environments can cross absolute ceilings. A scale result describes the measured backend and workload, not every transport or deployment.

## Evidence

`zig build test` holds allocation and footprint contracts. `zig build perf-check` owns timing tripwires. [Benchmarks](../../../bench/README.md) records measurement procedures and the distinction between product paths and primitive costs.
