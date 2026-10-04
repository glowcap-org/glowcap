---
name: debugging
description: "Use when a gate is red, a test fails or flakes, a process hangs, or behavior is wrong and the cause is unknown: evidence before theory, ordered suspects, halving the search, and a fix that explains the symptom."
---

# glowcap — Debugging

A failure is data. Rerunning until green, patching the symptom, and weakening
the assertion each destroy it.

## Evidence before theory

- Read the first error and the exit code, not the last line or the log's tone.
  A gate passes by exit code ([cli rule](../../rules/cli.md#gates)).
- Reproduce alone and small before changing anything: the narrowest failing
  step, `-Dtest-filter=<name>`, and a deadline around anything that dials. A
  failure you cannot reproduce alone is not yet a fact, and fixing a flake
  produces a real defect.
- For protocol behavior, read `conformance/` (pinned Goblins source, upstream
  suite, draft spec) before designing around the failure.

## Suspects, in order

1. **Environment:** a rival build holding the lease, an orphaned test binary,
   an inherited port. Inspect the lease owner and its children first.
2. **This session's diff.** "It compiles" clears types, not lifetimes or
   assumptions.
3. **The platform** (Zig, std, OS, pinned crates, the Goblins peer), only after
   a minimal reproduction containing none of glowcap convicts it.

## Halve the search

Cut the suspect space in half by varying one condition between a passing and a
failing case: half the diff, the input, the scenario, or the history (read-only
`git log`/`git show`). Probe edits restore from a copy saved in the scratchpad,
never from `git checkout`/`git restore`.

A candidate fix is the most expensive experiment and rules out only itself.
Two disproved fixes in a row means the search is running on guesses: go measure
a difference instead. Reach for a fix once you can say what breaks.

## Prove, don't assume

When reasoning passes through "this can't be null / reordered / reused," make it
observable: an assert, a focused test, or a log written to a file with `>|`
(zsh `noclobber` silently keeps a stale log on `>`). Write the causal chain from
symptom to root in one paragraph; where it stalls is the missing knowledge.

A probe that reports nothing may be aimed wrong. Before filing "the feature does
nothing," make the same harness show a positive case working.

## Closing

- The fix accounts for the original evidence and lands at the owning layer
  ([resilience](../../rules/resilience.md)). Green comes from the fix, never
  from a retreat ([prerelease](../../rules/prerelease.md)).
- Ask where else this shape lives, and which check should have caught it. Land
  that check with the [ratchet skill](../ratchet/SKILL.md).
