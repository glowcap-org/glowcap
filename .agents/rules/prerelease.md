---
description: "glowcap is prerelease: no compatibility debt, so the default verdict on a design event is to fix the root now, not defer it."
alwaysApply: true
---

# glowcap — Prerelease Posture

Nothing in glowcap is released. Break unreleased APIs, ABIs, and storage
formats cleanly and update their consumers and evidence together. Add no
migration, compatibility shim, or held-back dependency to preserve an
unreleased contract. External protocol interop still answers to its outside
authority. A replaced prerelease contract keeps version `1`. Increment only to
support a distinct older contract on purpose.

"It would change a shared type," "touch the spine," and "ripple through callers"
name a migration cost, and there is none to pay. None justifies a workaround,
a named compromise, or a follow-up PR when the clean fix is in reach this
session. Before accepting a compromise, re-derive it against the full option
set, not the binary it first presents, and name any survivor in the open.

Living docs and comments describe the current shape. Keep transition
narration, old names, and review labels in git or an owning ADR. State missing
work as a present boundary.

## A bug is not a verdict on the design

A defect found while a design lands is usually evidence about the
implementation. Before reverting, classify it:

- **A missing prerequisite** (an idempotent verb, a durable owner, a reset
  boundary): build it. It is usually smaller than the revert.
- **A contradiction in the design's own terms:** only this earns a retreat.

On a red gate, the cheapest green is a retreat: revert the default, weaken
the assertion, raise the budget, skip the step. Each leaves an unfixed defect
behind a passing build. Reproduce alone first (the
[debugging skill](../skills/debugging/SKILL.md)), read `conformance/` before
designing around protocol behavior, then classify and act. Reporting a defect
does not close it.

Ask the human only when the answer turns on what only they know: a product
call, a priority, an outside commitment. When these rules already answer the
question, decide, do it, and say why.
