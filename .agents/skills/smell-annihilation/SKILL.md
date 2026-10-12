---
name: smell-annihilation
description: >-
  Use for structural cleanup, layer moves, duplication collapse, wire-path cost
  hunts, or when a timid first fix smells like deferred migration cost. Not for
  one-line fixes, pure questions, or OCapN/Goblins community-review preflight
  (community-review).
---

# Smell annihilation: ambition and discipline

Find the architecture the code should have, move things where they belong, and
enforce it so it cannot rot back. Ambition without the gate is reckless, and
the gate without ambition stagnates. The ambition is the
[Release Bar](../../rules/project-values.md): a networking library, not a
polite CapTP port.

Distrust a smaller first fix that imports a phantom migration cost
([prerelease](../../rules/prerelease.md)). Re-derive against the full option
set, including moving a type, splitting a layer, or relocating logic, before
accepting a nullable, shim, facade, or follow-up PR.

## Leave it better (kaizen)

A pass that opens a surface owes it a higher floor when it closes, beyond the
named fault. This is the Release Bar's rule for touched surfaces, aimed at the
escape hatch prerelease already waives: keeping cruft because "someone might
still need it" or "a follow-up will delete it."

- **Delete dead code in the same change** when the pass makes it unreachable:
  unread fields, capture spans nobody reads, unused `len`/`at` spines,
  forwarding wrappers over a type that already moved. Grep and the compiler are
  the authority on callers.
- **Keep no second representation "for safety"** once the structural owner
  exists. It is phantom compatibility cost.
- Small sharpening on the opened path (a clearer owner, one fewer clone, a
  stale living-state claim fixed) compounds. Leaving scar tissue is a failed
  pass even when the original bug is gone.

Persona **titles and proper names** may appear in subagent prompts and session
plans. They never appear in committed code or comments; taste lands as
structure ([agent-scaffolding](../../rules/agent-scaffolding.md)).

## When not to use

- One-line fixes or pure questions with a focused rule already naming the path
- OCapN / Goblins community-review preflight → [community-review](../community-review/SKILL.md)
- Multi-persona room team ops → [rooms-team](../rooms-team/SKILL.md)

## Persona lookup

Resolve slugs per [`.agents/personas/README.md`](../../personas/README.md)
(project then XDG). The operator names the two slugs; this skill hardcodes no
defaults. A missing slug stops the run. For scaffolding-only scopes a useful
pair is `scaffold-rigor` plus a domain lens, still operator-chosen.

## Memory, performance, optimums

Architecture that ignores cost is incomplete. Every pass treats allocation,
copy, lifetime, and asymptotic shape as smells of the same severity as a wrong
layer or a dual-typed struct. Authority:

- [memory](../../rules/memory.md): owned transfer, bounded borrow; copy helpers
  stay in test support.
- [project-values](../../rules/project-values.md): a wire-path allocation or
  copy is a design event, so **forbid it, name it, or measure it.**
- [ladder](../../../docs/ladder.md) Step 2: checked budgets (alloc floor,
  footprint, `perf-check` tripwires).

**Optimum** is the structure that makes the cheap correct path the *only* path:
one owner, one spine, one materialize, zero hidden copies. Do not trade a
cleaner type for a quieter alloc on the hot path, and do not "optimize" a named
allocation without re-deriving its contract against the full option set
([prerelease](../../rules/prerelease.md) and the ledger in memory.md).

When scoping and when briefing personas, demand a verdict on each candidate
move:

| Verdict | Meaning |
| ------- | ------- |
| **forbid** | Delete the alloc/copy/re-walk; structure makes it impossible. |
| **name** | It must stay; document why (and prefer a gate/test that pins the count). |
| **measure** | Shape is unclear: bench or alloc-budget proof before landing taste. |
| **own-pass** | Real win, but bigger than this session; defer with the cost claim intact. |

Persona output includes, per finding: path (wire / session / host / test),
alloc or copy delta (before→after or "none"), lifetime owner, and the verdict.
A "cleanup" that adds a steady-state heap hit or an O(n) re-walk on
`at`/`toOwned` without a forbid/name/measure line is incomplete.

## The loop

1. **SCOPE.** Fault / ideal / false constraint, one sentence each. Name the
   memory/perf stake in the ideal (what becomes impossible, what budget holds).
2. **REVIEW WITH TWO INDEPENDENT PERSONAS.** Spawn two subagents on the real
   tree, because you have blind spots in code you wrote. Resolve each slug,
   inject that file's body into the subagent prompt, and order both:

   > Read the code, don't hand-wave; say where something is already right;
   > do not invent nits; propose, do not edit, I will execute.
   > Treat wire-path cost and ownership as architecture: forbid / name / measure
   > each alloc, copy, and re-walk you touch; prefer the structure that makes the
   > cheap path the only path.

   Demand from each: findings prioritized most-impactful-first, exact
   `file:line`, exact before→after (or the deletion), the principle each move
   serves, blast radius, forbid/name/measure/own-pass on cost, and a hard split
   of `do-now` (clean, gate-able) vs `own-pass` (bigger).
3. **SYNTHESIZE.** Keep candidates where they agree. Where they disagree,
   decide and say why; a held design-taste split is a finding. Escalate
   anything both flag as a real defect (including a silent wire-path cost).
   Never execute a review blindly.
4. **EXECUTE** when the user asked for implementation. Prefer the root fix over
   the workaround. Delete the dead code the fix exposes, and land living-state
   docs and budget pins in the same change when a cost contract changes.
5. **GATE.** See below. Exit code is authority; never skim output through
   `tail`/`grep` (that reports the pipe's status).
6. **DEFER.** Name non-moves with real reasons (including "measure first") and
   scope each as its own pass. Never half-land a big move.

## Smell classes to hunt

Most rows below are the "DRY, orthogonal, and easier to change" value in
[project-values](../../rules/project-values.md) failing in one concrete shape.
A duplicated spine breaks one authority per fact, a change that drags an
unrelated concern breaks orthogonality, and a boundary held by convention is
harder to change. Name the principle a finding breaks.

- Sans-io / pure logic trapped inside an I/O or adapter type (extract it where
  the build bans I/O).
- The same control-flow spine written N times across sibling types (unify onto
  one core; the others become thin callers).
- A type that is secretly two types, told apart by a nullable / mode flag and
  scattered `.?` checks (split it; delete the flag).
- A real boundary held only by convention (make it a build-checked invariant).
- A file that has outgrown one responsibility. First-party sources stop at
  650 lines (`tools/check/source_check/file_length.zig`); overages are
  explicit ceilings that only shrink. Split on a seam the file already names,
  not by chopping at the cap, and drop or lower the exception in the same
  change. The procedure is [file-budget](../file-budget/SKILL.md).
- Parallel hierarchies that re-express what a shared core could hold.
- Behavior gaps hiding inside duplication (a hand-rolled copy that dropped
  something the canonical path does; unification fixes these).
- A wire-path or steady-state allocation/copy that is neither forbidden, named
  in the [memory ledger](../memory-ledger/SKILL.md), nor pinned by a
  budget/bench.
- An owned value that is really a key into a durable owner already on the path
  (drop the copy; retain through the owner).
- A borrowed view that forces O(n) re-walks (`at` from start each call) when
  one materialize or cursor walk would serve every consumer.
- A "helper" that clones to paper over lifetime confusion at a boundary.
- Dead fields / capture spans retained "for callers" that no caller reads
  (delete them).

## The apex move

Make a smell's return structurally impossible. Turn the lesson into a gate: a
build check, an enforced layer boundary, an alloc/footprint budget test, a
`perf-check` ceiling, or a scenario that pins the contract. A build that
rejects the violation beats a rule you must remember. The best pass leaves the
gate longer and the prose shorter.

## Discipline

- On a risky structural move, validate incrementally: land the smallest slice
  that proves the mechanism, then move the piece the rest depends on.
- Let the compiler and the gate enumerate the work: change structure, then fix
  exactly what they flag, in a tight red→green loop.
- Never leave the tree red. Every pass ends green or does not end.
- Leave a touched surface sharper, with code, tests, and living-state docs
  aligned in the same change. Dead code on that surface is in scope.
- Cost claims need evidence: `alloc_budget` / footprint tests, encode budgets, or
  the ReleaseFast tripwires inside `zig build check`. Taste without a number is
  a hypothesis: mark it **measure** or **own-pass**.

## Done

The full gate is green; the fault is fixed and structurally prevented; dead
code the pass exposed is gone; duplication is gone or deferred with a reason;
wire-path costs are forbidden, named, or measured; the public surface is
unchanged or deliberately swept; no committed code carries a persona's proper
name; the next agent inherits a higher floor.

## On this codebase

- **Gate:** `zig build check` (includes alloc/footprint budgets and
  `perf-check`). Focused: `zig build test`, `arch-check`, `source-check`,
  `fmt-check`.
- **Live CapTP while editing:** [glowcap-mcp](../glowcap-mcp/SKILL.md),
  [glowcap-cli](../glowcap-cli/SKILL.md), [rooms-peer](../rooms-peer/SKILL.md).
  Invent no Zig dialer.
- **Layer bans:** `build.zig` `layer_table` + `arch-check` (`core = true` bans
  `std.Io`).
- **Cost authority:** [memory](../../rules/memory.md) and its
  [ledger](../memory-ledger/SKILL.md), ladder Step 2,
  `test/engine/alloc_budget_test.zig`, `test/engine/footprint_budget_test.zig`,
  `test/codec/encode_budget_test.zig`, `bench/*` ceilings.
- **Prerelease posture:** [`.agents/rules/prerelease.md`](../../rules/prerelease.md).
- **Settled architecture:** [`docs/decisions/adr/`](../../../docs/decisions/adr/).
