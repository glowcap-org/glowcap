---
name: work
description: >-
  Use when starting substantial glowcap work, scoping features, architectural
  moves, naming or module-boundary sweeps, release readiness, multi-file
  refactors, or reviews that should end in action or evidenced inaction. Skip
  for one-line fixes and pure questions where a focused rule already specifies
  the path.
---

# glowcap — Work Skill

Substantial work leaves glowcap closer to [`docs/vision.md`](../../../docs/vision.md)
and easier to continue. Assess, then act or prove inaction. A defect discovered
while executing an item may block it; fixing that defect clears the block and
immediately resumes the original item—it does not redefine completion.

## When not to use

- One-line fixes or pure questions where a focused rule already specifies the path
- Structural smell / layer / cost hunts → [smell-annihilation](../smell-annihilation/SKILL.md)
- OCapN / Goblins community-review preflight → [community-review](../community-review/SKILL.md)

## 1. Load context (strategic, not exhaustive)

Read only what the task needs:

Economy is a routing rule, not a quality bar. Start with the smallest
authoritative slice, widen the moment a claim depends on another surface, and
prefer generated inventories or build steps over re-deriving facts by hand.
Release review starts with the core invariants and failure paths, then follows
their consumers outward. Record what each layer's evidence establishes and what
remains open before expanding to the next layer. A green gate or one repaired
defect does not establish that the underlying design is sound.

| If the task touches…                                  | Read first                                                                                                 |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Scope, APIs, naming, structure, release bar           | [`docs/vision.md`](../../../docs/vision.md)                                                                |
| Layer ownership, protocol authority, module placement | [`docs/architecture.md`](../../../docs/architecture.md) + [architecture rule](../../rules/architecture.md) |
| Frames, allocators, wire-path copies                  | [memory rule](../../rules/memory.md)                                                                       |
| Semantic claims, fixtures, conformance                | [tests rule](../../rules/tests.md) + `test/oracle/`                                                        |
| Docs, README, agent scaffolding                       | [doc-drift](../../rules/doc-drift.md) + [doc-voice](../../rules/doc-voice.md)                              |
| Dependency or toolchain updates                       | [cli](../../rules/cli.md#devcontainer) + [prerelease](../../rules/prerelease.md)                           |
| Live CapTP from the shell (argv/REPL/listen/`--json`) | [glowcap-cli skill](../glowcap-cli/SKILL.md)                                                               |
| Live CapTP via Cursor/Claude MCP tools                | [glowcap-mcp skill](../glowcap-mcp/SKILL.md) — dogfood CapTP while editing glowcap                         |
| Room presence wake-loop                               | [rooms-peer skill](../rooms-peer/SKILL.md)                                                                   |
| A settled boundary or vocabulary choice               | matching ADR under `docs/decisions/adr/`                                                                   |
| OCapN current direction (settled or pending)          | updated `conformance/ocapn-spec/upstream/`: draft, recent minutes, and the owning live proposal            |

For Zig symbols — modules, types, renames, reference walks — use Serena first
per the [serena skill](../serena/SKILL.md).

## 2. Assess and execute

Name the changed contract, its owner, affected consumers, and the evidence that
will establish correctness. Check the shape against the vision: protocol
semantics, explicit ownership and costs, a sync no-I/O core, and usable APIs.
An awkward boundary or missing symmetric path is implementation work, not a
reason to preserve the first design.

Fix the cause at its owning seam. Prefer types, shared boundaries, generated
mirrors, and behavior checks to instructions that callers must remember. Keep
code, tests, generated state, and living documentation aligned in the same
change. Apply the [prerelease posture](../../rules/prerelease.md) to unreleased
contracts. A load-bearing decision belongs in an ADR.

Proceed within the requested scope. If a discovered defect blocks that work,
fix it and resume the original task. Leave unrelated work intact. A decision
to leave a suspected problem alone needs evidence or an existing documented
boundary; passing an unrelated gate is insufficient.

### Review the diff cold

After a coherent stretch of work, inspect the result as if someone else wrote
it. Include code added earlier in this session. Answer:

- **Cause:** Does the change remove the defect's class at its owner, or only
  suppress the observed instance?
- **Symmetry:** Which other targets, features, transports, directions, and
  callers share the contract? Exercise the affected sibling paths.
- **Consumers:** What assumed the old ownership, lifetime, format, or refusal
  behavior? Compilation alone cannot prove those assumptions still hold.
- **Truth:** Which docs, examples, generated files, and rules became untrue?
- **Coupling:** What fact did the diff repeat, and what unrelated concern did
  it require changing? Collapse duplication at the shared owner.
- **Optimum:** How far is the result from the obvious design the
  [release bar](../../rules/project-values.md#release-bar) describes?

Fix findings within scope. Name any untested path or remaining boundary
explicitly; do not convert an unresolved design question into a green-check
claim.

## 3. Verify

Use the [execution rule](../../rules/cli.md#gates) to choose focused checks
while iterating and the final gates for the changed boundaries. It owns evidence
reuse, build leases, deadlines, and failure diagnosis. A scaffolding-only edit
uses `source-check`, plus `infrastructure-check` when executable workflow
behavior changes; it does not require the product gate.

Invoke builds through the worktree's environment front:

```sh
.agents/skills/work/bin/glowcap-dev zig build source-check
```

The front and lease are links to their canonical implementations under
`.devcontainer/bin/`. Continue independent work during a long check while
preserving its inputs. Browser proofs require stable generated assets for the
whole run. A host-side live service needs a PTY so Ctrl-C reaches its children.

Commit or integrate only when the user has authorized it. The
[Git posture](../../rules/cli.md#git-posture) owns the worktree procedure,
including `.agents/skills/work/bin/glowcap-integrate --sync` and publication
through `.agents/skills/work/bin/glowcap-integrate`. A generic direction to
continue work does not itself authorize either operation.

## 4. Ratchet and hand off

Update `docs/shipped.md` and `docs/boundaries.md` when product behavior or
boundaries change. Fix drift on touched surfaces. An unresolved limitation
needs a living owner, not an unowned deferral marker.

Run the [ratchet review](../ratchet/SKILL.md): encode reusable lessons at their
strongest owner and prune instructions they replace. If existing guidance
already covers the lesson, no additional rule is needed. Report the outcome,
relevant verification and its limits, and what the ratchet changed or why
nothing qualified.
