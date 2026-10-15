---
description: "Doc kinds, audiences and headers, and claims that match current code or are removed."
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

This rule keeps doc claims true, and [doc-voice](doc-voice.md) keeps them readable.
Apply both whenever you touch a doc.

A state claim either matches current code, or the claim or the doc is removed.
A doc changes in the same diff as the state it describes. Work goes from idea
to roadmap item to plan to execution. A roadmap item links its own
plan, or the permanent [plan to plan](../../docs/planning/plan-to-plan.md)
until it has one. `docs/vision.md` may argue a destination, but its
present-tense claims are held like any other.

**Each fact has one home.** Before adding a list, table, index, or status
line, check whether another doc already holds it and link that doc instead.

- The roadmap is the only list of work, and a plan holds its own steps and
  status.
- A change that must edit several docs to stay true is a defect. Remove the
  copies instead of updating them.
- When a doc must restate what code or a manifest declares, generate it from
  that source and check it, the way `gen-dependencies` writes
  `docs/dependencies.md`.
- A number a doc quotes from a code constant sits between value markers that
  `gen-doc-values` fills ([`doc_values.zig`](../../tools/gen/doc_values.zig)
  shows the form). If the code has only a bare literal, name it first.
- A site page cannot hold markers, so it links the repo doc that quotes the
  number.

**Every doc has a kind and an audience.**
[`kinds.zig`](../../tools/check/source_check/docs/kinds.zig) owns both
definitions and the header schema, and `source-check` holds them. Where a
doc's place decides both (agent homes, site pages, root docs, decision records,
plans), the place is the authority. Every other doc opens with an OKF header:
`type` (its kind), a one-sentence `description`, an optional `audience`, and
`sources`, the code it explains. Before adding a doc, decide all four. A doc
whose place decides it already names its sources by what it links and puts in
code spans, so it carries no second list.

- Kind is how long the doc lives. **Static** docs state facts that hold until
  the code changes, use no status words, and are the default. **Living** pages
  stay and say where the project stands, so status lives there. **Temporary**
  docs (plans, for one) are committed, owned by a living page that
  links them, and deleted when their job is done. **Temporary local** docs sit
  under the ignored `.local/`.
- Links point from what changes to what stays. A static doc may link a living
  page or its headings, never a temporary doc, so deleting one edits nothing
  else. No committed doc links into `.local/`.
- Audience is who reads it: **human** pages for people using glowcap or
  running Rooms ([doc-voice](doc-voice.md) reader rules), **agent** docs that
  instruct an agent, and **shared** docs that both read while building
  glowcap.

Rules for every doc:

- Write present-tense contracts. No "future X" once X lands, no stale status
  markers, no "formerly" or transition narration. History lives in git or an
  ADR that still owns a decision.
- Do not hardcode a count the code can outgrow. Describe the set or cite the
  check that holds the number.
- A comment explaining a technique names the condition under which it is
  available, not only its motive, because rationale without its precondition
  gets ported to sites where it does not hold. When two similar functions
  differ, the more careful one says why the cheaper path is closed to it.
- A rename or file move sweeps docs, tests, examples, and agent rules in the
  same change. Grep the old name and path across the tree, because a path
  written as a string is invisible to every typechecker.
- A change rereads the docs that explain the code it touched:
  `zig build doc-impact` lists them from those sources. A source path that
  moves or disappears fails `source-check`, and so does a qualified code name
  in a static doc (`Host.close`, `Failure::parse`) that part of the code no
  longer declares.
- Source comments use the indicative only for mechanisms with a real caller,
  and name the implementing symbol. A Zig doc comment naming `Type.method` is
  checked against `src/` (`checkZigDocSymbolClaims`), and a bare camelCase
  name must be spelled in code (`checkZigDocBareNames`). Fix the name or
  delete the claim. A private function no code in its file calls is dead
  (`checkZigDeadPrivateFns`): delete it with the path it served.
