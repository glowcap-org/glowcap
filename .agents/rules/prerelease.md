---
description: "Published alpha contracts may change cleanly. Explain breaking changes and required user action instead of preserving compatibility by default."
alwaysApply: true
---

# glowcap — Prerelease Posture

The [alpha release policy](../../docs/maintaining.md#release-status) permits
API, ABI, and storage changes before 1.0. Published alpha contracts have
users even without a compatibility guarantee. Change a contract cleanly,
update its consumers and evidence together, and document breaking changes
and required action in the changelog. A required state reset is explicit and
operator-controlled. External protocol interop still answers to its outside
authority.

Do not add a migration, compatibility shim, or held-back dependency solely
to preserve an alpha contract. A replaced contract keeps version `1`.
Increment only to support a distinct older contract on purpose. Cross-layer
changes are implementation work, not grounds for a workaround or deferral
when the clean fix is in scope. Weigh any compromise against the full option
set and name the remaining cost.

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
