---
name: work
description: >-
  Use when starting substantial pancake work, scoping features, architectural
  moves, naming or module-boundary sweeps, release readiness, multi-file
  refactors, or reviews that should end in action or evidenced inaction. Skip
  for one-line fixes and pure questions where a focused rule already specifies
  the path.
---

# pancake — Work Skill

Substantial work on pancake should leave the repository closer to
[`docs/vision.md`](../../../docs/vision.md) and easier for the next agent to
continue. Assess first, then act or prove inaction, do not stop at a report
when the right move is to fix what you found.

## When not to use

- One-line fixes or pure questions where a focused rule already specifies the path
- Structural smell / layer / cost hunts → [smell-annihilation](../smell-annihilation/SKILL.md)
- OCapN / Goblins community-review preflight → [community-review](../community-review/SKILL.md)

## 1. Load context (strategic, not exhaustive)

Read only what the task needs:

| If the task touches…                                  | Read first                                                                                                 |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Scope, APIs, naming, structure, release bar           | [`docs/vision.md`](../../../docs/vision.md)                                                                |
| Layer ownership, protocol authority, module placement | [`docs/architecture.md`](../../../docs/architecture.md) + [architecture rule](../../rules/architecture.md) |
| Frames, allocators, wire-path copies                  | [memory rule](../../rules/memory.md)                                                                       |
| Semantic claims, fixtures, conformance                | [tests rule](../../rules/tests.md) + `test/oracle/`                                                        |
| Docs, README, agent scaffolding                       | [doc-drift](../../rules/doc-drift.md) + [doc-voice](../../rules/doc-voice.md)                              |
| Live CapTP from the shell (argv/REPL/listen/`--json`) | [pancake-cli skill](../pancake-cli/SKILL.md)                                                               |
| Live CapTP via Cursor/Claude MCP tools                | [pancake-mcp skill](../pancake-mcp/SKILL.md) — dogfood CapTP while editing pancake                         |
| Room presence wake-loop                               | [rooms-peer skill](../rooms-peer/SKILL.md)                                                                   |
| A settled boundary or vocabulary choice               | matching ADR under `docs/decisions/adr/`                                                                   |
| OCapN spec text (when semantics are unclear)          | `conformance/ocapn-spec/`                                                                                  |

For Zig symbols — modules, types, renames, reference walks — use Serena first
per [serena-mcp rule](../../rules/serena-mcp.md).

## 2. Assess (every touched surface)

- **Inevitability:** Would a competent reader think this is the obvious shape
  for an OCapN implementation at this layer? If not, that gap is the work.
- **Names:** Do file, module, type, and function names say what they own?
- **Boundaries:** Is authority in session, I/O in adapters, semantics out of
  codecs? Is the core still sync and no-I/O?
- **Evidence:** Does every semantic claim have a scenario, oracle trace, or
  Goblins fixture? A wish is not shipped.
- **Polish:** Would a rough edge here multiply across every future contribution?

**Decide:**

- **Act** when any answer is "no" and you can fix it within scope. Load-bearing
  architectural or naming changes are in scope when they are the right move.
- **Inaction** only with evidence: gates pass, vision gap is a documented
  boundary (README, vision, or ADR), not neglect dressed as prudence.

## 3. Execute

- Prefer no-footgun structure (types, boundaries, build gates) over comments.
- Same change: code + tests + living-state docs. Write or supersede an ADR when
  the move is load-bearing.
- Do not commit external taste-reference names from prompts; encode intent as
  Zig-native control, protocol vocabulary, and tests.
- Match surrounding code. Minimal correct diff beats a wide cosmetic sweep.

### Three questions before "done"

A review of finished-looking work finds the same three classes every time, and
each is a question that was never asked rather than a skill that was missing.
Ask them while the work is open, not after a reviewer finds them.

**Does the other half do this?** A capability built and proven on one side is
half-built. Name the symmetric cases explicitly — dial and accept, the near
and the far target, each transport whose designator or hint is load-bearing,
each tier that shares the surface — and write the test for the side you did
*not* build first. Every memory-safety and wire defect found in the owning
host face lived on the untested half: the accept path's unwind, the listening
half's dial table, the keyed transport's hint. The happy-path proof is the one
that cannot see them. Treat "not in this phase" as a deferral, never a
contract: name the living owner of the remaining work and still inventory every
sibling surface the changed contract governs.

**Who believed the old contract?** When what a function owns, retains,
borrows, or refuses changes, the compiler checks types, not lifetimes.
Enumerate every caller and ask what each assumed. A slice that used to be
borrowed for one call and is now retained for a session dangles in every
caller that built it on a frame — and it compiles, links, and runs until the
retained path fires.

**What did this change make untrue?** Sweep referrers in the same diff, before
declaring done: rules, ADRs, living-state docs, generated headers, examples,
comments naming an owner or a tier. A claim that outlives the code it
described is worse than no claim, and the agent rules are the worst place for
one because the next session acts on them without checking.

## 4. Verify

```sh
zig build check
```

Use focused gates while iterating (see [cli rule](../../rules/cli.md)).

## 5. Compound (leave the next agent better off)

- Update `docs/shipped.md` and `docs/boundaries.md` when behavior or boundaries
  change.
- Fix doc drift in files you touched; leave prose more readable than you found
  it.
- Do not leave "someone should fix X later" without recording X as a present
  boundary in vision, `docs/boundaries.md`, or an ADR.
- Scaffolding changes: update `tools/check/meta_check.zig` in the same change.
