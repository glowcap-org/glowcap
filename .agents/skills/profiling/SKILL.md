---
name: profiling
description: "Use when a path is slow, a performance claim needs attribution, or a change should pay for itself: profile a bench's marked phases under callgrind, rank self cost, change the top of the list, then measure."
---

# glowcap — Profiling

A wall-clock figure says a path is slow. A profile says where the
instructions go. Attribute before changing, and measure after.

## The step

A bench's `profile-*` step runs it under callgrind, built ReleaseFast for the
baseline CPU with valgrind client requests on, and writes
`zig-out/bench-reports/<bench>-profile.md`. `docs/build-steps.md` lists the
profiled benches, and `bench/README.md` says how to read a report. Pass the
bench's own filters after `--`, as in
`zig build profile-loam -- --tasks-only --engine=sqlite`, so one run
attributes one workload.

- Profile the ReleaseFast shape. Debug ranks safety checks and missed inlining.
- Rank self cost by function, then by file. Inclusive cost and call trees
  follow inlining, so the function at the top is where instructions execute
  and the bench source says who asked for them.
- Ir repeats exactly for one build on any machine. Keep the report from
  before a change and diff the phase totals after it. A lower Ir on the
  marked phase is the attribution; the bench's ReleaseFast wall-clock run is
  still the claim ([bench/README.md](../../../bench/README.md)).
- Callgrind multiplies the bench's own time by tens, so profile the smallest
  workload that reaches the path, and prefer a bench filter to a longer
  deadline.

## Marking a phase

A bench marks what it measures with `bench/support/profile.zig`: `begin()`
before the timed loop, `end("<phase>")` after it. Each phase is one callgrind
part, collected alone, so setup and teardown count nothing. Name the phase
what the bench's report row calls it. A new bench joins the `profile-*` family
through its table row in `tools/build/bench.zig` or its own registration in
`tools/build/loam.zig`.

## Reading the result

- A hashing, checksum, or decode function at the top of a read path is a
  question about what the path recomputes, not about the function. The
  callers table under a leaf names who asked.
- `memcpy` at the top with hundreds of instructions per call is a large
  value passed or returned by value on a hot path. Borrow it or build it in
  place.
- A linear scan at the top at app scale is a table that needs an index.
- Cost in the driver loop at the top is a pump that spins without work.
- A function that stays at the top after a change was not the cause. Diff
  the Ir totals before concluding anything.
