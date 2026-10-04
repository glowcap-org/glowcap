---
description: "Doc-drift discipline for Zig glowcap: living-state claims must describe current code or be removed."
globs: **/*.md, site/content/**, .cursor/*.json, .claude/*.json, .mcp.json, .serena/*.yml
paths:
  - "**/*.md"
  - "site/content/**"
  - ".cursor/*.json"
  - ".claude/*.json"
  - ".mcp.json"
  - ".serena/*.yml"
---

# glowcap — Doc Drift

This rule keeps doc claims true; [doc-voice](doc-voice.md) keeps them readable.
Apply both whenever you touch a doc.

A state claim either matches current code, or the claim or the doc is removed.
Living-state surfaces change in the same diff as the state they describe. The
registry is `tools/check/source_check/docs/living_state.zig`; a new top-level
`docs/*.md`, a `docs/` subdirectory page saying "Living-state surface", or a
planning doc with `Status: living-state` must be added there. Planning docs
declare `Status: active plan`, `historical`, or `living-state`, and an active
plan is linked from `docs/roadmap.md` or `docs/upstream-watch.md`.
`docs/vision.md` may argue a destination, but its present-tense claims are
held like any other.

- Write present-tense contracts. No "future X" once X lands, no stale status
  markers, no "formerly" or transition narration; history lives in git or an
  ADR that still owns a decision.
- Do not hardcode a count the code can outgrow; describe the set or cite the
  check that holds the number.
- A comment explaining a technique names the condition under which it is
  available, not only its motive. Rationale without its precondition gets
  ported to sites where it does not hold. When two similar functions differ,
  the more careful one says why the cheaper path is closed to it.
- A rename or file move sweeps docs, tests, examples, and agent rules in the
  same change. Grep the old name and path across the tree; a path written as a
  string is invisible to every typechecker.
- Source comments use the indicative only for mechanisms with a real caller,
  and name the implementing symbol. A Zig doc comment naming `Type.method` is
  checked against `src/` (`checkZigDocSymbolClaims`); fix the name or delete
  the claim.
