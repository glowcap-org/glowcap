---
name: smell-annihilation
description: >-
  Use for structural cleanup, layer moves, duplication collapse, wire-path cost
  hunts, or when a timid first fix smells like deferred migration cost. Not for
  one-line fixes, pure questions, or OCapN/Goblins community-review preflight
  (community-review).
---

# Smell annihilation: ambition and discipline

Find the owner and interface that make correct behavior easiest, move the
implementation there, and verify the result against the
[release bar](../../rules/project-values.md#release-bar).

Compare a local fix with moving a type, splitting a layer, or relocating logic.
Before adding a nullable, shim, facade, or follow-up PR, establish which
constraint requires it. Handle contract changes under the
[alpha policy](../../rules/prerelease.md).

## When not to use

- One-line fixes or pure questions with a focused rule already naming the path.
- OCapN and Goblins community-review preflight: [community-review](../community-review/SKILL.md).
- Room team operations: [rooms-team](../rooms-team/SKILL.md).

## Leave it better (kaizen)

A pass that opens a surface owes it a higher floor when it closes, beyond the
named fault. Replace alpha contracts with their consumers and documented
release impact handled together, per the [prerelease policy](../../rules/prerelease.md).

- **Delete dead code in the same change** when the pass makes it unreachable:
  unread fields, capture spans nobody reads, unused `len`/`at` spines,
  forwarding wrappers over a type that already moved. Grep and the compiler are
  the authority on callers.
- **Remove a superseded representation** once all consumers use its owner.
- Improve the path you touch: clarify ownership, remove unnecessary clones,
  and correct stale documentation.

## Memory, performance, optimums

Architecture that ignores cost is incomplete. Treat allocation, copy,
lifetime, and asymptotic shape as smells of the same severity as a wrong layer
or a dual-typed struct. The [memory rule](../../rules/memory.md) owns the
ownership model, and [milestones](../../../docs/milestones.md) step 2 names what holds
the budgets.

The optimum is the structure that makes the cheap correct path the only path:
one owner, one spine, one materialize, zero hidden copies. Do not trade a
cleaner type for a quieter alloc on the hot path, and do not "optimize" a named
allocation without re-deriving its contract against the full option set
([prerelease](../../rules/prerelease.md) and the ledger in memory.md).

When scoping and when briefing reviewers, demand a verdict on each candidate
move. A wire-path allocation or copy is **forbidden, named, or measured**:

| Verdict | Meaning |
| ------- | ------- |
| **forbid** | Delete the alloc/copy/re-walk. Structure makes it impossible. |
| **name** | It must stay. Document why and prefer a gate or test that pins the count. |
| **measure** | The shape is unclear. Land a bench or alloc-budget proof before taste. |
| **own-pass** | Real win, but bigger than this session. Defer with the cost claim intact. |

Each reviewer's output includes, per finding, the path (wire, session, host, or test),
the alloc or copy delta (before to after, or "none"), the lifetime owner, and
the verdict. A "cleanup" that adds a steady-state heap hit or an O(n) re-walk
on `at`/`toOwned` without a forbid, name, or measure line is incomplete.

## The loop

1. **SCOPE.** State the defect, the intended ownership and behavior, and the
   constraints on changing them. Name the memory or performance requirement
   and the check that will establish it.
2. **REVIEW WITH TWO INDEPENDENT READERS.** When the user asked for
   independent reviewers, spawn two subagents on the real tree, because you
   have blind spots in code you wrote. Otherwise read the tree twice
   yourself, one concern per pass. Give each reader a different concern (the layer boundary, the wire-path cost) and order both:

   > Read the code, don't hand-wave; say where something is already right;
   > do not invent nits; propose, do not edit, I will execute.
   > Treat wire-path cost and ownership as architecture: forbid / name / measure
   > each alloc, copy, and re-walk you touch; prefer the structure that makes the
   > cheap path the only path.

   Demand from each:
   - Findings prioritized most-impactful-first, with exact `file:line`.
   - The exact change from before to after, or the deletion.
   - The principle each move serves and its blast radius.
   - Forbid, name, measure, or own-pass on cost.
   - A hard split of `do-now` (clean, gate-able) and `own-pass` (bigger).
3. **SYNTHESIZE.** Keep candidates where they agree. Where they disagree,
   decide and say why. A held design-taste split is a finding. Escalate
   anything both flag as a real defect, including a silent wire-path cost.
   Never execute a review blindly.
4. **EXECUTE** when the user asked for implementation. Prefer the root fix over
   the workaround, delete the dead code the fix exposes, and land the docs and
   budget pins in the same change when a cost contract changes.
5. **GATE.** Read the exit code and never skim output through `tail`/`grep`,
   which reports the pipe's status. See [On this codebase](#on-this-codebase) for the steps.
6. **DEFER.** Name non-moves with real reasons (including "measure first") and
   scope each as its own pass. Never half-land a big move.

## Smell classes to hunt

Most rows below are the "one authority per fact" and "small modules, sharp
boundaries" values in [project-values](../../rules/project-values.md) failing
in one concrete shape. Name the principle a finding breaks.

- Sans-io or pure logic trapped inside an I/O or adapter type. Extract it where
  the build bans I/O.
- The same control-flow spine written N times across sibling types. Unify onto
  one core and make the others thin callers.
- A type that is secretly two types, told apart by a nullable or mode flag and
  scattered `.?` checks. Split it and delete the flag.
- A real boundary held only by convention. Make it a build-checked invariant.
- A file that has outgrown one responsibility. Split on a seam the file
  already names, not by chopping at the line limit, per
  [file-budget](../file-budget/SKILL.md).
- Parallel hierarchies that re-express what a shared core could hold.
- Behavior gaps hiding inside duplication, such as a hand-rolled copy that
  dropped something the canonical path does. Unification fixes these.
- A wire-path or steady-state allocation or copy that is neither forbidden,
  named in the [memory ledger](../memory-ledger/SKILL.md), nor pinned by a
  budget or bench.
- An owned value that is really a key into a durable owner already on the path.
  Drop the copy and retain through the owner.
- A borrowed view that forces O(n) re-walks (`at` from start each call) when
  one materialize or cursor walk would serve every consumer.
- A "helper" that clones to paper over lifetime confusion at a boundary.
- Dead fields or capture spans retained "for callers" that no caller reads.
  Delete them.

## The apex move

Make a smell's return structurally impossible by turning the lesson into a
gate: a build check, an enforced layer boundary, an alloc or footprint budget
test, a `perf-check` ceiling, or a scenario that pins the contract. The best
pass leaves the gate longer and the prose shorter. The
[agent-scaffolding](../../rules/agent-scaffolding.md#landing-a-lesson) rule says where it lands.

## Discipline

- On a risky structural move, validate incrementally: land the smallest slice
  that proves the mechanism, then move the piece the rest depends on.
- Let the compiler and the gate enumerate the work: change structure, then fix
  exactly what they flag, in a tight red-to-green loop.
- Never leave the tree red. Every pass ends green or does not end.
- Back cost claims with evidence: `alloc_budget` and footprint tests, encode
  budgets, or the ReleaseFast tripwires inside `zig build check`. Taste without
  a number is a hypothesis, so mark it **measure** or **own-pass**.

## Done

- The full gate is green and the fault is fixed and structurally prevented.
- Dead code the pass exposed is gone.
- Duplication is gone or deferred with a reason.
- Wire-path costs are forbidden, named, or measured.
- The public surface is unchanged or deliberately swept.
- The next agent inherits a higher floor.

## On this codebase

- **Gate:** `zig build check` (includes alloc/footprint budgets and
  `perf-check`). Focused: `zig build test`, `arch-check`, `source-check`,
  `fmt-check`.
- **Live CapTP while editing:** [glowcap-mcp](../glowcap-mcp/SKILL.md),
  [glowcap-cli](../glowcap-cli/SKILL.md), [rooms-peer](../rooms-peer/SKILL.md).
  Invent no Zig dialer.
- **Layer bans:** `build.zig` `layer_table` and `arch-check` (`core = true` bans
  `std.Io`).
- **Cost authority:** the [memory rule](../../rules/memory.md) and its
  [ledger](../memory-ledger/SKILL.md), the `*_budget_bytes` constants,
  `test/engine/alloc_budget_test.zig`, `test/engine/footprint_budget_test.zig`,
  `test/codec/encode_budget_test.zig`, and `bench/*` ceilings.
- **Settled architecture:** [`docs/decisions/adr/`](../../../docs/decisions/adr/).
