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
  failure you cannot reproduce alone is not a fact. A flake has a cause, and
  fixing it fixes a real defect.
- For protocol behavior, read `conformance/` (pinned Goblins source, upstream
  suite, draft spec) before designing around the failure.

## Many failures at once

When several proofs fail, take the whole inventory in one concurrent run (the
Rooms browser family runs in parallel, per `apps/rooms/developing.md`), then
group failures by first error before fixing any, since one cause often owns a
cluster. Probe in a copy of the failing proof kept outside the repository,
with console capture, DOM dumps and screenshots, so product sources never
carry diagnostic logging into the next build. When a proof's wait passes but
the next step fails, suspect the wait: a transitional state can satisfy it,
such as a destination title over the old composer.

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
After two disproved fixes in a row, stop guessing and measure a difference.
Write a fix once you can say what breaks.

## Prove, don't assume

When reasoning passes through "this can't be null / reordered / reused," make it
observable: an assert, a focused test, or a log written to a file with `>|`
(zsh `noclobber` silently keeps a stale log on `>`). Write the causal chain from
symptom to root in one paragraph. Where it stalls is the missing knowledge.

A probe that reports nothing may be aimed wrong. Before filing "the feature does
nothing," make the same harness show a positive case working.

## Closing

- The fix accounts for the original evidence and lands at the owning layer
  ([resilience](../../rules/resilience.md)). Green comes from the fix, never
  from a retreat ([prerelease](../../rules/prerelease.md)).
- Ask where else this shape lives, and which check should have caught it. Land
  that check with the [ratchet skill](../ratchet/SKILL.md).
