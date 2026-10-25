---
description: "The scaffolding is a public API whose consumers are agents. Keeping claims true, the scaffolding gate, the ratchet, and the budget. Load before changing anything under .agents/, AGENTS.md, overlays, hooks, or skills."
globs: AGENTS.md, .agents/**, .claude/**, .cursor/**, .codex/**, .pi/**
paths:
  - "AGENTS.md"
  - ".agents/**"
  - ".claude/**"
  - ".cursor/**"
  - ".codex/**"
  - ".pi/**"
---

# glowcap — Agent Scaffolding

Agent guidance is a public API whose consumers are every future session. Keep
its ownership, scope, and failure behavior as precise as a product interface.

- **Claims stay true.** When a path, command, or convention changes, update or
  remove its claims in the same diff ([doc-drift](doc-drift.md)).
- **Edit canonical files only** (`AGENTS.md`, `.agents/**`). Never write through
  the `CLAUDE.md` or `.cursor/rules/*.mdc` symlinks, because an in-place edit
  turns them into regular files and the overlay dies.
- **Gates.** Static scaffolding answers to `zig build source-check`.
  Executable devcontainer, worktree, and hook behavior answers to
  `zig build infrastructure-check`. `tools/check/source_check.zig` and its
  modules are the inventory of what is checked, so read them before assuming a
  claim is unchecked.
- **Routing.** A rule is resident (`alwaysApply: true`) only when nearly every
  session needs it. Otherwise it is scoped by `globs:` plus a matching quoted
  `paths:` list, or it is a skill. Procedures, inventories, and reference data
  are skills or check tables, never rules.

## The budget

Every resident line is paid by every session. Each concern has one owner, and
other surfaces link to it. Additions displace or compress existing prose. Write
directives with their precondition and reason, and cut persuasion, repetition,
and anecdote.

- When a check enforces a list or ban, keep the list in the check and drop the
  prose copy.
- Name current contracts positively. An old-name ban is a tombstone that
  belongs in the ADR and git history once the move lands.

Committed guidance names protocol vocabulary, owners, boundaries, and
evidence, never people to emulate. Commit messages describe what the diff
demonstrates, with a short subject and no session machinery.

## The ratchet

Before handing off, ask what the session learned that guidance did not teach.
A human correction always triggers this. Land the lesson at its strongest
owner (a check, regression test, fixture, rule line, or deletion) and validate
a new check against the defect it claims to catch. Existing coverage is a valid
outcome. The [ratchet skill](../skills/ratchet/SKILL.md) is the procedure.
