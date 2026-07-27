---
description: "Doc-drift discipline for Zig pancake: living-state claims must describe current code or be removed."
globs: **/*.md, src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, build.zig, .cursor/*.json, .claude/*.json, .mcp.json, .serena/*.yml
---

# pancake — Doc Drift Prevention

This rule keeps doc claims _true_. Its sibling, [doc-voice](doc-voice.md), keeps
human-facing prose _readable_ (speech for a person; agent instruction stays
under `.agents/**`). Run the two together whenever you touch a doc.

Every doc surface that makes a state claim must satisfy one of:

1. the claim matches current code;
2. the doc is removed;
3. the state claim is removed.

## Living-State Surfaces

These describe the repository as it is now and must be updated in the same
change as the state they describe:

- `README.md`
- `CONTRIBUTING.md`
- `SECURITY.md`
- `PROVENANCE.md`
- `docs/vision.md`
- `docs/architecture.md`
- `docs/ladder.md`
- `docs/roadmap.md`
- `docs/capabilities.md`
- `docs/consuming-from-c.md`
- `docs/cli.md`
- `docs/shipped.md`
- `docs/stability.md`
- `docs/boundaries.md`
- `docs/community-review.md`
- `docs/decisions/README.md`
- `docs/protocol-diagrams/**`
- `site/content/**`
- `bindings/README.md`
- `bindings/rust/README.md`
- `bindings/ts/README.md`
- `bindings/python/README.md`
- `bindings/racket/README.md`
- `examples/README.md`
- `apps/README.md`
- `tools/README.md`
- `ui/README.md`
- `bench/goblins/README.md`
- `conformance/ocapn-findings/README.md`
- `.devcontainer/README.md`
- `AGENTS.md`
- `.agents/**`
- `.cursor/README.md`, `.cursor/*.json`, and `.cursor/rules/*.mdc`
- `.claude/README.md`, `.claude/*.json`, and `.claude/rules`
- `.mcp.json` and `.serena/project.yml`
- test names that encode API contracts

`zig build meta-check` holds this registry honest in both directions: every
top-level `docs/*.md`, every planning doc that declares itself living-state, and
every doc under a `docs/` subdirectory that declares itself a living-state
surface must be listed here (a covering glob like `docs/protocol-diagrams/**`
counts), and every non-glob path listed here must exist.

`docs/vision.md` is the one surface that argues a destination: its aspirational
prose is not drift, but its present-tense claims (what is implemented versus
not, build-step and API names) are gated like any other and move with the code.

Other `README.md` files are not automatically living-state surfaces. Classify
them by role:

- living-state when they are a first-read project/subsystem contract;
- historical-snapshot when they record a moment and say so;
- operational notes when they describe local workflow without project-state
  claims.

`docs/planning/**` is not a first-read contract by default. A planning file must
say whether it is an active plan, a historical snapshot, or a living-state
surface; do not let old plan language masquerade as current architecture.

## Discipline

- Prefer present-tense contracts over project-history narration.
- Do not write "future X" once X has landed; name what exists and what does not.
- Do not leave stale status markers in living-state docs.
- Do not hardcode a count the code can outgrow ("all fifteen arms"); describe
  the set, or cite the gate that holds the number.
- If a line — or a whole historical-snapshot file — only explains how the
  current shape came to be, the record belongs in git history: prune it once the
  work it captured has shipped and its lessons live in the code, ADRs, or
  living-state docs. A snapshot is a transition, not a permanent home.
- When an API name changes, sweep docs, tests, examples, and agent rules in the
  same change. A rename that updates its target file and leaves the referrers
  behind is the commonest drift here, and the compiler will not catch it in
  prose: grep the old name across the tree before calling the rename done.
- A Zig doc comment naming `Type.method` is a claim `zig build meta-check`
  checks (`checkZigDocSymbolClaims`): the method must be declared under `src/`.
  Fix the name or delete the claim; do not weaken the check.
- When scaffolding topology changes, update `.agents/README.md`,
  `tools/check/meta_check.zig`, and the affected tool overlay docs together.
