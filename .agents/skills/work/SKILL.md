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

Economy is a routing rule, not a quality bar. Start with the smallest
authoritative slice, widen the moment a claim depends on another surface, and
prefer generated inventories or build steps over re-deriving facts by hand.

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
| OCapN current direction (settled or pending)          | updated `conformance/ocapn-spec/upstream/`: draft, recent minutes, and the owning live proposal            |

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
- Use automation to save reasoning, never evidence: if a check or generated
  spine can hold the invariant, wire it or run it instead of asking future agents
  to remember it.
- Same change: code + tests + living-state docs. Write or supersede an ADR when
  the move is load-bearing.
- Do not commit external taste-reference names from prompts; encode intent as
  Zig-native control, protocol vocabulary, and tests.
- Match surrounding code. Minimal correct diff beats a wide cosmetic sweep.

### Four questions before "done"

A review of finished-looking work finds the same few classes every time, and
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

**What did this diff repeat, and what did it drag?** Scan the finished diff
against the "DRY, orthogonal, and easier to change" value in
[project-values](../../rules/project-values.md). Logic, tables, or claims the
diff stated twice collapse at the layer that owns them. A change that had to
touch an unrelated concern is a coupling to name or fix, not a chore to
finish. Where two representations could carry one fact, prefer the shared seam, the
generated mirror, or the build check over the parallel copy.

### Step back before calling it done

Asking the four questions while heads-down is not the same as reading the work
cold. **After each focused stretch of execution, stop and review what you just
built as though someone else wrote it**, and do it as often as the work keeps
changing shape rather than once at the end.

This is the cheapest quality step available and it catches what nothing else
does. A living-state doc still describing the gap the diff just closed. One
explanation copy-pasted into every binding instead of living at its one
authority. A knob added with no caller that exercises it. A test broken by a
later widening in the same session. An asymmetry between two neighbours that
turns out to be a missing mechanism rather than a style difference.

Two things make it work. **Nothing is exempt for being recent**: code touched
an hour ago, or held up as the model the rest were matched to, gets read with
the same suspicion as code from a year ago, because being fresh in mind is not
the same as being right. And **an unproven claim is named, not implied**: when
a path cannot be covered hermetically, say so where it lives rather than let a
green suite imply it was checked.

Act on what the pass finds, including in your own work from earlier in the
same session. The fix is the deliverable; the findings are not. A pass that
ends in a list of what someone else should do has moved the work rather than
done it, and it costs the reader the time the pass was supposed to save.
Mention only what changes the reader's decisions: a defect that alters how
they use the thing, or a judgement call that was theirs to make.

## 4. Verify

```sh
zig build check
```

Use focused gates while iterating (see [cli rule](../../rules/cli.md)).
When host tooling is missing but the devcontainer is already running, invoke the
same command through `.agents/skills/work/bin/pancake-dev`, for example
`.agents/skills/work/bin/pancake-dev zig build source-check`.

When the user has directed worktree commits into the shared `dev` integration
ref, start a clean work stint with
`.agents/skills/work/bin/pancake-integrate --sync`; it rebases onto the current
`main` and `dev` without publishing. Commit only explicit owned paths, then run
`.agents/skills/work/bin/pancake-integrate` without the flag to absorb both
shared lines again and fast-forward `dev`. Both modes discover the current
branch from Git; the worktree/container name is deliberately not an input.

## 5. Compound (leave the next agent better off)

- Update `docs/shipped.md` and `docs/boundaries.md` when behavior or boundaries
  change.
- Fix doc drift in files you touched; leave prose more readable than you found
  it.
- Do not leave "someone should fix X later" without recording X as a present
  boundary in vision, `docs/boundaries.md`, or an ADR. `zig build source-check`
  refuses unowned deferral markers in first-party source for the same reason.
- Scaffolding changes answer to
  [agent-scaffolding](../../rules/agent-scaffolding.md): the lesson lands at the
  strongest layer that can hold it, and the gate moves in the same change. The
  [ratchet skill](../ratchet/SKILL.md) is the landing procedure.
