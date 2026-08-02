---
name: smell-annihilation
description: >-
  Use for structural cleanup, layer moves, duplication collapse, wire-path cost
  hunts, or when a timid first fix smells like deferred migration cost. Not for
  one-line fixes, pure questions, or OCapN/Goblins community-review preflight
  (community-review).
---

# Smell annihilation — ambition + discipline

Find the architecture the code should have, move things where they belong, and
enforce it so it cannot rot back. Ambition without the gate is recklessness; the
gate without ambition is stagnation. Hold both.

Distrust the first, smaller fix when it imports a phantom migration cost
([prerelease](../../rules/prerelease.md)). Re-derive against the full option set —
including moving a type, splitting a layer, or relocating logic — before accepting
a nullable, shim, facade, or follow-up PR.

## Leave it better (kaizen)

Every pass that opens a surface owes a higher floor when it closes — not only
the named fault. That is the Release Bar's "no half measures on touched
surfaces," aimed at the same escape hatch prerelease already waives: keeping
cruft because "someone might still need it" or "a follow-up will delete it."

- **Delete dead code in the same change** when the pass makes it unreachable:
  unread fields, capture spans nobody reads, unused `len`/`at` spines,
  forwarding wrappers that only paper over a type that already moved. Do not
  assume a caller; grep and the compiler are the authority.
- **Do not retain a second representation "for safety"** once the structural
  owner exists — that is a phantom compatibility cost under another name.
- Small sharpening on the opened path (a clearer owner, one fewer clone, a
  stale living-state claim fixed) compounds; leaving the scar tissue for the
  next agent is a failed pass even if the original bug is gone.

Persona **titles and proper names** may appear in subagent prompts and session
plans. They must never appear in committed code or comments; taste lands as
structure ([agent-scaffolding](../../rules/agent-scaffolding.md)).

## When not to use

- One-line fixes or pure questions with a focused rule already naming the path
- OCapN / Goblins community-review preflight → [community-review](../community-review/SKILL.md)
- Multi-persona room team ops → [rooms-team](../rooms-team/SKILL.md)

## Persona lookup

Resolve slugs per [`.agents/personas/README.md`](../../personas/README.md)
(project then XDG). Operator names the two slugs; this skill does not hardcode
defaults. Missing slug → stop. For scaffolding-only scopes, a useful pair is
`scaffold-rigor` + a domain lens — still operator-chosen.

## Memory, performance, optimums

Architecture that ignores cost is incomplete. Every pass treats allocation,
copy, lifetime, and asymptotic shape as first-class smells — the same severity
as a wrong layer or a dual-typed struct. Authority:

- [memory](../../rules/memory.md) — owned transfer, bounded borrow; copy helpers
  stay in test support.
- [project-values](../../rules/project-values.md) — a wire-path allocation or
  copy is a design event: **forbid it, name it, or measure it.**
- [ladder](../../../docs/ladder.md) Step 2 — checked budgets (alloc floor,
  footprint, `perf-check` tripwires), not folklore.

**Optimum** here means: the structure that makes the cheap correct path the
*only* path. Prefer one owner, one spine, one materialize, zero hidden copies.
Do not trade a cleaner type for a quieter alloc on the hot path, and do not
"optimize" a named load-bearing allocation without re-deriving its contract
against the full option set ([prerelease](../../rules/prerelease.md) + the
load-bearing list in memory.md).

When scoping and when briefing personas, demand an explicit verdict on each
candidate move:

| Verdict | Meaning |
| ------- | ------- |
| **forbid** | Delete the alloc/copy/re-walk; structure makes it impossible. |
| **name** | It must stay; document why (and prefer a gate/test that pins the count). |
| **measure** | Shape is unclear — bench or alloc-budget proof before landing taste. |
| **own-pass** | Real win, but bigger than this session; defer with the cost claim intact. |

Persona output must include, per finding: path (wire / session / host / test),
alloc or copy delta (before→after or "none"), lifetime owner, and which verdict
above. A "cleanup" that adds a steady-state heap hit or an O(n) re-walk on
`at`/`toOwned` without a forbid/name/measure line is incomplete.

## The loop

1. **SCOPE.** Fault / ideal / false constraint — one sentence each. Name the
   memory/perf stake in the ideal (what becomes impossible, what budget holds).
2. **REVIEW WITH TWO INDEPENDENT PERSONAS.** Spawn two subagents on the real
   tree (not you — you have blind spots in code you wrote). Resolve each slug,
   inject that file’s body into the subagent prompt, and order both:

   > Read the code, don't hand-wave; be honest where something is already right;
   > do not invent nits; propose, do not edit — I will execute.
   > Treat wire-path cost and ownership as architecture: forbid / name / measure
   > each alloc, copy, and re-walk you touch; prefer the structure that makes the
   > cheap path the only path.

   Demand concrete output from each: prioritized most-impactful-first, exact
   `file:line`, exact before→after (or the deletion), the principle each move
   serves, blast radius, forbid/name/measure/own-pass on cost, and a hard split
   of `do-now` (clean, gate-able) vs `own-pass` (bigger).
3. **SYNTHESIZE.** Where they agree, keep the candidate. Where they disagree,
   decide and say why — a held design-taste split is a finding. Escalate anything
   both flag as a real defect (including a silent wire-path cost). Do not
   blindly execute a review.
4. **EXECUTE** when the user asked for implementation. Prefer the root fix over
   the workaround. Delete the dead code the fix exposes; land living-state docs
   and budget pins in the same change when you change a cost contract.
5. **GATE.** See below. Exit code is authority; never skim output through
   `tail`/`grep` (that reports the pipe’s status).
6. **DEFER HONESTLY.** Name non-moves with real reasons (including "measure
   first"); scope them as their own pass. Never half-land a big move.

## Smell classes to hunt

Most rows below are the "DRY, orthogonal, and easier to change" value in
[project-values](../../rules/project-values.md) failing in one concrete shape.
A duplicated spine breaks one authority per fact, a change that drags an
unrelated concern breaks orthogonality, and a boundary held by convention is
the shape harder to change. Name which principle a finding breaks.

- Sans-io / pure logic trapped inside an I/O or adapter type (extract it where
  the build bans I/O).
- The same control-flow spine written N times across sibling types (unify onto
  one core; others become thin callers).
- A type that is secretly two types, told apart by a nullable / mode flag and
  scattered `.?` checks (split it; delete the flag).
- A boundary that is real but only conventional (turn it into a build-checked
  invariant).
- Parallel hierarchies that re-express what a shared core could hold.
- Behavior gaps hiding inside duplication (a hand-rolled copy that dropped
  something the canonical path does — unification fixes these for free).
- A wire-path or steady-state allocation/copy that is neither forbidden, named
  in [memory](../../rules/memory.md), nor pinned by a budget/bench.
- An owned value that is really a key into a durable owner already on the path
  (drop the copy; retain through the owner).
- A borrowed view that forces O(n) re-walks (`at` from start each call) when
  one materialize or cursor walk would serve every consumer.
- A "helper" that clones to paper over lifetime confusion at a boundary.
- Dead fields / capture spans retained "for callers" that no caller reads
  (delete; do not keep a second representation warm).

## The apex move

Do not merely fix a smell — make its return structurally impossible. Turn the
lesson into a gate: a build check, an enforced layer boundary, an alloc/footprint
budget test, a `perf-check` ceiling, or a scenario that pins the contract. “A
rule you must remember” is weaker than “a build that rejects the violation.”
The best pass leaves the gate longer and the prose shorter.

## Discipline

- On a risky structural move, validate incrementally: land the smallest slice
  that proves the mechanism, then move the load-bearing piece.
- Let the compiler and the gate enumerate the work — change structure, then fix
  exactly what they flag, in a tight red→green loop.
- Never leave the tree red. Every pass ends green or does not end.
- When you touch a surface, leave it sharper — code, tests, and living-state docs
  aligned in the same change. Dead code on that surface is in scope; prerelease
  means you do not assume it must stay.
- Cost claims need evidence: `alloc_budget` / footprint tests, encode budgets, or
  the ReleaseFast tripwires inside `zig build check`. Taste without a number is
  a hypothesis — mark it **measure** or **own-pass**, do not ship it as fact.

## What “done” looks like

The full gate is green; the fault is fixed and structurally prevented; dead code
the pass exposed is gone; duplication is gone or honestly deferred; wire-path
costs are forbidden, named, or measured; the public surface is unchanged or
deliberately swept; nothing in committed code carries a persona’s proper name;
the next agent inherits a higher floor.

## On this codebase

- **Gate:** `zig build check` (includes alloc/footprint budgets and
  `perf-check`). Focused: `zig build test`, `arch-check`, `meta-check`,
  `fmt-check`.
- **Live CapTP while editing:** [pancake-mcp](../pancake-mcp/SKILL.md) ·
  [pancake-cli](../pancake-cli/SKILL.md) · [rooms-peer](../rooms-peer/SKILL.md)
  — do not invent a Zig dialer.
- **Layer bans:** `build.zig` `layer_table` + `arch-check` (`core = true` bans
  `std.Io`).
- **Cost authority:** [memory](../../rules/memory.md), ladder Step 2,
  `test/engine/alloc_budget_test.zig`, `test/engine/footprint_budget_test.zig`,
  `test/codec/encode_budget_test.zig`, `bench/*` ceilings.
- **Prerelease posture:** [`.agents/rules/prerelease.md`](../../rules/prerelease.md).
- **Settled architecture:** [`docs/decisions/adr/`](../../../docs/decisions/adr/).
