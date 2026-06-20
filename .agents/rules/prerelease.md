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
