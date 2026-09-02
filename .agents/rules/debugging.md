---
description: "glowcap debugging discipline: evidence before theory, ordered suspects, halve the search, and a fix that explains the symptom."
alwaysApply: true
---

# glowcap — Debugging

A failure is data. The cheap moves — rerun until green, patch the symptom,
weaken the assertion — destroy that data. This rule is the method that keeps
it, and it is cheaper than every shortcut around it.

## Evidence before theory

Read the actual failure before forming a hypothesis: the first error, not the
last, and the exit code, not the log's tone (a gate passes by exit code; the
[cli rule](cli.md) owns that). Then make the failure reproducible and small:
the narrowest build step that still fails, `-Dtest-filter` when a test name
matches, `timeout N` around anything that dials. A failure you cannot
reproduce alone is not yet a fact.

## The order of suspects

1. **The environment.** Rival builders, orphaned test binaries, an inherited
   port. The [cli rule](cli.md) names these sweeps; run them before touching
   code.
2. **This session's change.** The newest diff is the prime suspect, always.
   "It compiles" clears types, not lifetimes or assumptions.
3. **The platform, last.** Zig, std, the OS, the pinned crates, and the
   Goblins peer are each innocent until a minimal reproduction containing
   none of your code convicts them. "The toolchain is broken" is almost
   always "my assumption is broken"; prove it outside glowcap before
   designing around it.

## Halve the search

When the suspect space is large, do not walk it linearly. Cut it in half and
test the half: half the diff (probe edits restore from a saved copy, never
from git; see the [cli rule](cli.md)), half the input, half the scenario,
half the history with read-only `git log` and `git show`. Each cut is one
question with a yes-or-no answer.

Cut by varying one condition, not by trying a fix. A candidate fix is the most
expensive experiment available — it costs a design plus a full verification
round — and when it fails it has told you almost nothing, because a fix that
does not work rules out only itself. Varying one condition between a case that
passes and a case that fails costs a probe edit and rules out half the space
whichever way it lands. So when you have a passing reproduction and a failing
one, spend the next move on the difference between them, and keep spending
there until the mechanism is named. Reach for a fix once you can say what
breaks, not to find out.

The tell that this rule is being broken: two candidate fixes in a row have been
disproved. That is not bad luck and it does not mean the next guess is due. It
means the search is being driven by guesses about the cause rather than by
evidence of it, and the cost per guess is the highest in the table. Stop and go
find a difference to measure. Never let it become a reason to leave the bug
alone: the answer to a hunt going badly is a cheaper question, not a smaller
ambition.

## Prove, don't assume

The defect lives in an assumption nobody tested. When your reasoning passes
through "this can't be null / reordered / reused," stop and make that
assumption observable: an assert, a focused test, or a log line written to a
file (subprocess stderr is often swallowed, and under zsh's `noclobber` a plain
`>` silently refuses an existing path, so the stale log reads as the fresh one —
write with `>|`). Then write the causal chain from symptom to root in one
paragraph. Where the writing stalls is where knowledge is missing.

**A harness that reports nothing is making a claim about itself.** Absence is
the one result a driven probe produces just as readily when it is aimed wrong:
a synthetic click outside the region it meant to hit, a scenario whose
precondition never armed. So before believing "the feature does nothing," make
the same harness show a positive — drive the case that must work and watch it
work. Uncalibrated, a negative is a finding about the probe, and filing it as a
defect spends someone else's session confirming your harness was broken.

## A fix explains the symptom

A patch that makes the failure disappear without accounting for how the
symptom arose is a coincidence, and the defect is still there. Before calling
it fixed: the explanation covers the original evidence, the root is fixed at
the layer that owns it ([resilience](resilience.md)), and green came from the
fix, not from a retreat ([prerelease](prerelease.md) holds that line).

## Then ratchet

Two questions close every hunt: where else does this exact shape live (the
[work skill](../skills/work/SKILL.md)'s symmetric-case question), and which
check should have caught it. Land that check per
[agent-scaffolding](agent-scaffolding.md); the
[ratchet skill](../skills/ratchet/SKILL.md) is the landing procedure.
