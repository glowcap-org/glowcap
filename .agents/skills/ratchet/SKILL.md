---
name: ratchet
description: >-
  Use when a session learned something the scaffolding does not already teach,
  after any human correction, or when landing a new rule, skill, or build
  check: encode the lesson at the strongest layer that can hold it, validate
  it against the defect it claims to catch, and prune what stopped paying
  rent. Not for ordinary code work (work) or structural cleanup
  (smell-annihilation).
---

# Ratchet — land the lesson

[agent-scaffolding](../../rules/agent-scaffolding.md) defines the ratchet:
every session ends by asking what it learned that the scaffolding did not
already teach, and the lesson lands before the session does. This skill is
the landing procedure.

## 1. Name the lesson

One sentence: the mistake a future agent could repeat, or the move that
worked and is not yet taught. If it does not fit in one sentence, it is a
topic, not a lesson; split it.

## 2. Choose the strongest layer

| The lesson is…                 | It lands as                    | Where                                                                  |
| ------------------------------ | ------------------------------ | ---------------------------------------------------------------------- |
| Mechanically checkable         | a build check                  | `tools/check/meta_check/` (§3), or `arch_check.zig` for layer imports  |
| A semantic or protocol fact    | a test, fixture, or scenario   | the placement map in [tests](../../rules/tests.md)                     |
| A judgment no check can hold   | the sharpest rule line         | the rule that owns the surface, per the [index](../../README.md)       |
| A line that stopped paying rent | a deletion                    | wherever it sits                                                       |

Prose is the weakest layer. A rule sentence that could be a check is a check
not yet written; when the check lands, the sentence shrinks to a pointer.

## 3. Landing a check

- Pick the module by concern: `scaffolding.zig` (overlays, indexes,
  frontmatter, this very map), `docs.zig` (markdown, links, site, prose),
  `project_shape.zig` (build steps, layer and test placement),
  `bans.zig` (substring claims over a scope), `zig_docs.zig` (doc-comment
  symbol claims), `fuzz.zig` (fuzz targets, seeds, the vendored runner),
  `namespaces.zig` (bare keyed tables), `signing_domain.zig` (durable-key
  signing sites and the Ed25519-to-X25519 bridge), `ui.zig` and
  `rooms_ui.zig` (the shared UI core and the rooms page), and the C ABI,
  binding, and CapTP
  spines: `c_abi.zig`, `binding_spine.zig`, `binding_runtime_proof.zig`,
  `captp_io_spine.zig`, `captp_product.zig`. The driver
  [`meta_check.zig`](../../../tools/check/meta_check.zig) wires every check,
  and `checkRatchetModuleMap` holds this list complete in both directions.
- A substring claim is one `Ban` row in a table joined into `bans.all`;
  prefer a row over bespoke code. Anything needing parsing or cross-file
  state is a `pub fn check…` in the owning module, called from the driver.
- **Validate the check against the defect it claims to catch.** Introduce the
  violation, watch `zig build meta-check` name it, then remove it. A check
  that has never fired has proven nothing — the same discipline
  [tests](../../rules/tests.md) demands of a new property target.
- Checks pay rent too: prefer one general check to fifty string bans, and
  retire stale tombstones per agent-scaffolding's "The gate accretes too."

## 4. Landing a rule or skill edit

- A rule is `.agents/rules/<name>.md` with frontmatter (`description:` plus
  `globs:` or `alwaysApply: true`), one symlink
  `.cursor/rules/<name>.mdc -> ../../.agents/rules/<name>.md`, and a row in
  the [rules table](../../README.md). `.claude/rules` is a directory
  symlink; there is nothing to add there.
- A skill is `.agents/skills/<name>/SKILL.md` with frontmatter whose `name:`
  equals the directory name, plus rows in both the
  [skills catalog](../README.md) and the [index](../../README.md).
- The budget binds every addition: find the sentence the new line displaces
  or compresses before writing it, and put it in the rule that owns the
  surface, never a new grab-bag rule.

## 5. Prune

Half the ratchet is removal. Retire prose a landed check now holds (shrink
it to a pointer at the check), tombstones whose rename shipped everywhere,
and hedged lines a sharper one replaced. A deletion is a full-fledged
landing, not maintenance deferred.

## Verify

`zig build meta-check` holds the topology, both indexes, links, frontmatter,
and documented build steps. Run it before calling the landing done.
