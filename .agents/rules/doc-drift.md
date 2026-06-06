---
description: "Doc-drift discipline for Zig pancake: living-state claims must describe current code or be removed."
globs: **/*.md, src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, build.zig, .cursor/*.json, .claude/*.json, .mcp.json, .serena/*.yml
---

# pancake — Doc Drift Prevention

Every doc surface that makes a state claim must satisfy one of:

1. the claim matches current code;
2. the doc is removed;
3. the state claim is removed.

## Living-State Surfaces

These describe the repository as it is now and must be updated in the same
change as the state they describe:

- `README.md`
- `docs/architecture.md`
- `AGENTS.md`
- `.agents/**`
- `.cursor/README.md`, `.cursor/*.json`, and `.cursor/rules/*.mdc`
- `.claude/README.md`, `.claude/*.json`, and `.claude/rules`
- `.mcp.json` and `.serena/project.yml`
- public doc comments on exported Zig declarations
- test names that encode API contracts

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
- If a line only explains how the current shape came to be, move that context to
  a PR/commit message or remove it.
- When an API name changes, sweep docs, tests, examples, and agent rules in the
  same change.
- When scaffolding topology changes, update `.agents/README.md`,
  `tools/meta_check.zig`, and the affected tool overlay docs together.
