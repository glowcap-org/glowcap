---
description: "The scaffolding is a public API whose consumers are agents. Keeping claims true, the scaffolding gate, the budget, and landing a lesson. Load before changing anything under .agents/, AGENTS.md, overlays, hooks, or skills."
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

Every resident line is paid by every session, and `source-check` caps the
resident set (`AGENTS.md` plus every `alwaysApply: true` rule) at
<!-- value ../../tools/check/source_check/agents_catalog.zig resident_budget_bytes -->18,000<!-- /value --> bytes. Each concern has one owner, and
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

## Landing a lesson

Before handing off, ask what the session learned that guidance did not teach.
A human correction always triggers this. Existing coverage is a valid outcome.
Otherwise land the lesson at the strongest layer that holds it, and shrink the
prose it replaces to a pointer:

| The lesson is | It lands as |
| --- | --- |
| A static cross-file fact | a check under `tools/check/source_check/`, or `arch_check.zig` for layer imports |
| Executable workflow behavior | a regression test under the gate that runs the workflow |
| A semantic or protocol fact | a test, fixture, or scenario placed by [tests](tests.md) |
| A judgment no check can hold | one line in the rule that owns the surface |
| A line that stopped paying rent | a deletion |

A new check is validated against the defect it claims to catch: introduce the
violation, watch the check fail for that reason, restore, and require a pass.
A new rule or skill needs frontmatter, the `.cursor/rules/<name>.mdc` symlink
for a rule, and `zig build gen-agent-index`. `source-check` names what is
missing.
