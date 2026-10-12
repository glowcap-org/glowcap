---
name: ratchet
description: >-
  Use when a session learned something the scaffolding does not already teach,
  after any human correction, or when landing a new rule, skill, or build
  check. Not for ordinary code work (work) or structural cleanup
  (smell-annihilation).
---

# Ratchet — land the lesson

[agent-scaffolding](../../rules/agent-scaffolding.md) defines the ratchet: a
session ends by asking what it learned that the scaffolding did not teach, and
the lesson lands before the session does. This skill is the landing
procedure.

## 1. Name the lesson

One sentence: the mistake a future agent could repeat, or the move that
worked and is not yet taught. A lesson that needs more than one sentence is a
topic; split it.

Check the existing owner first. If it already teaches or enforces the lesson,
report that and add nothing. The review is required, a new rule is not.

## 2. Choose the strongest layer

| The lesson is…                 | It lands as                    | Where                                                                  |
| ------------------------------ | ------------------------------ | ---------------------------------------------------------------------- |
| Static cross-file fact         | a source check                 | `tools/check/source_check/` (§3), or `arch_check.zig` for layer imports  |
| Executable workflow behavior   | a behavioral regression test  | `tools/check/`, wired into `infrastructure-check` for agent/container workflows |
| A semantic or protocol fact    | a test, fixture, or scenario   | the placement map in [tests](../../rules/tests.md)                     |
| A judgment no check can hold   | the sharpest rule line         | the rule that owns the surface, per the [index](../../README.md)       |
| A line that stopped paying rent | a deletion                    | wherever it sits                                                       |

Prose is the weakest layer. A rule sentence that could be a check is a check
not yet written; when the check lands, the sentence shrinks to a pointer.

## 3. Landing a check

- Test behavior by driving the owning interface and observing effects and
  failures. A substring in a script does not prove the script's behavior.
  Put static cross-file checks beside their concern under
  [`tools/check/source_check/`](../../../tools/check/source_check/) and wire it
  in [`source_check.zig`](../../../tools/check/source_check.zig). Layer-import
  checks belong in `arch_check.zig`; runtime dependency checks belong in
  `toolchain_check.zig`. Executable workflow regressions use their owning
  behavior gate instead of growing the static gate.
- A substring claim is one `Ban` row in a table joined into `bans.all`;
  prefer a row over bespoke code. Anything needing parsing or cross-file
  state is a `pub fn check…` in the owning module, called from the driver.
- **Validate the check against the defect it claims to catch.** Introduce the
  violation, watch the owning check fail for that reason, then restore the
  correct behavior and require a pass. A check that has never fired proves
  nothing, the same discipline [tests](../../rules/tests.md) demands of a new
  property target.
- Checks pay rent too: prefer one general check to fifty string bans, and
  retire stale tombstones (see agent-scaffolding's budget).

## 4. Landing a rule or skill edit

- A rule is `.agents/rules/<name>.md` with frontmatter (`description:` plus
  `globs:` or `alwaysApply: true`), one symlink
  `.cursor/rules/<name>.mdc -> ../../.agents/rules/<name>.md`, and a row in
  the [rules table](../../README.md). `.claude/rules` is a directory
  symlink; there is nothing to add there.
- A skill is `.agents/skills/<name>/SKILL.md` with frontmatter whose `name:`
  equals the directory name, plus a row in the [index](../../README.md).
- The budget binds every addition: find the sentence the new line displaces
  or compresses before writing it, and put it in the rule that owns the
  surface, not a new grab-bag rule.

## 5. Prune

Retire prose a landed check now holds (shrink it to a pointer at the check),
tombstones whose rename shipped everywhere, and hedged lines a sharper one
replaced. A deletion is a landing.

## Verify

`zig build source-check` holds the topology, indexes, links, frontmatter,
and documented build steps. Run it before calling the landing done.
