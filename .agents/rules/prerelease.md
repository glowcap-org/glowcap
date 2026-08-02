---
description: "pancake is prerelease: no compatibility debt, so the default verdict on a design event is to fix the root now, not defer it."
alwaysApply: true
---

# pancake — Prerelease Posture

pancake ships under no compatibility promise yet: no pinned wire format, no
frozen public API, no external consumer locked to a type's shape. That is a
license, and it sets the default verdict on every design event, **fix the root
now; do not defer it.**

The drift this guards against is importing a post-1.0 instinct into a pre-1.0
codebase. "It would change a shared type," "it would touch the spine," "it would
ripple through callers" all name a _migration_ cost, and there is no migration
to pay. None of them is, on its own, grounds to settle for a workaround, a named
compromise, or a follow-up PR when the clean fix is in reach this session.

So before accepting any compromise, re-derive it against the full option set,
not the binary the compromise first presents: a copy is not "copy vs. retain the
whole source" when one durable owner can hold the value; a shim is not "shim vs.
break the world" when the world is yours to change. A compromise earns its place
only if it survives that wider derivation, and then it is named in the open,
never hidden. This is the [Release Bar](project-values.md)'s "no half measures
on touched surfaces," pointed at its most common escape hatch: deferring a
structural fix on a cost prerelease has already waived.

## A bug is not a verdict on the design

A defect found while a design is landing is evidence about the implementation
far more often than about the design. Before reverting, name which one it is:

- **A missing prerequisite** the design assumed and nothing provides yet: an
  idempotent verb, a durable owner, a reset boundary. Build it. It is usually
  smaller than the revert, and the revert leaves the hole for the next session
  to rediscover.
- **A contradiction in the design's own terms**, where holding one invariant it
  needs breaks another. Only this earns a retreat, and it is rare.

Reverting on the first is the deferral above wearing a bug report as its excuse,
and the follow-up task naming the prerequisite is the tell. Nor does losing
confidence change the answer: work that was not trusted needs more verification,
not smaller changes.

**A red gate is where this rule is actually lost.** Everything above is easy to
agree with while the tree is green. The moment a gate fails mid-slice, "get back
to green" starts to feel like the job, and the cheapest green is always a
retreat: revert the default, weaken the assertion, raise the budget, skip the
step. Each one ends with a passing build and an unfixed defect, which is
strictly worse than the red gate, because the red gate was telling you something
and the green one is not.

Green is what a root fix produces, never a goal that outranks it. So when a gate
goes red on work you are landing:

- Reproduce it alone before believing it, and before changing anything: the
  [debugging rule](debugging.md) owns the method, and "fixing" a flake
  produces a real defect.
- Read the authority before designing around the failure. For protocol
  behavior that is `conformance/` — the pinned Goblins source and the upstream
  suite answer most "how is this supposed to work" questions outright, and a
  guess dressed as a design is the expensive path.
- Then name it a missing prerequisite or a contradiction, per the split above,
  and act accordingly.

Reporting the defect honestly instead of fixing it is not an exception to this.
An accurate description of an unfixed thing is still an unfixed thing.
