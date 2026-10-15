---
name: file-budget
description: >-
  Use when source-check reports a file over the line limit, or when a change
  would push a first-party source over it. This is the procedure for
  splitting a file by subject. Not for an unrelated one-line edit in a file
  well below the limit (work) or a structural pass whose purpose is not file
  size (smell-annihilation).
---

# File budget — split by subject

First-party source files stay under the limit `max_lines` in
[`file_length.zig`](../../../tools/check/source_check/file_length.zig), with
no exceptions. Split a file that would cross it before the change lands,
whoever wrote it. A successful split moves a whole subject behind a named
module boundary and leaves both sides easier to change. Moving lines without
moving ownership pays nothing.

Never game the count, because each of these turns visible debt into harder
debt:

- Minifying, combining independent statements, or weakening formatting.
- Deleting useful comments or evidence.
- Moving source under an ignored, generated, or vendor path.
- Creating `part1`, `misc`, `helpers`, or `common` dumping grounds.

Fix generated output at its generator and never hand-edit or hide it.

## Choose the seam before moving lines

Say in one sentence what the file owns. Inventory its state, public entry
points, imports, callers, and tests. A strong extraction candidate has at
least one of these boundaries:

- One authority over a table, lifecycle, or mutable state.
- One protocol operation or state-machine arm with its own invariants.
- One transport, binding projection, UI surface, build concern, or scenario
  family.
- A leaf vocabulary used by several siblings but owned by none of them.
- A section that changes and can be tested independently of its current file.

Extract the smallest complete subject that gives dependencies one direction:

- Move its state and invariants with its operations. If the old file still
  owns the state while the new file manipulates it through a wide helper
  surface, the boundary is cosmetic.
- If two proposed modules must import each other, extract their shared
  contract as a narrower leaf or choose a different owner.
- Keep each extracted file under the limit with one nameable subject.

Write the before-and-after shape before editing. For example, "the driver loop
owns admission and TCP provider policy" becomes "the loop owns admission, and
`tcp_provider` owns TCP lifecycle and exposes one narrow outcome contract." If
the second sentence is not clearer, the split is not ready.

## Extraction shapes that hold up

Use the language's ordinary module mechanism, and prefer a subdirectory to
sibling files when the pieces of one subject share a prefix, share a harness,
or would be read together. Drop the prefix from the names inside it
(`c_abi/host/close_test.zig`, not `c_abi/host_close_test.zig`). The directory
is the subject's one home: its shared fixtures live inside it, not in a global
support pool, and the next split has an obvious place to land.

These are shapes, not mandatory directory layouts:

- **Zig:** let a file be the namespace for one subject. Extract a named leaf or
  subdirectory module, keep mutable state with its owner, and expose only the
  types and operations the parent needs. Keep the parent as an orchestrator or
  deliberate public facade, not a forwarding copy of every child declaration.
- **C and the C ABI:** separate fixed-layout contracts, generated declarations,
  and implementation subjects without moving policy into the ABI. Keep one
  generator authority for mirrored headers and binding layouts.
- **Rust:** use subject-named modules and the narrowest visibility, usually
  private or `pub(crate)`. Do not turn `lib.rs` into a second implementation by
  re-exporting every internal.
- **TypeScript:** extract leaf modules and shared types so dependencies remain
  acyclic. A public barrel may preserve an intentional package surface, but an
  implementation module must not import back through that barrel.
- **Python:** keep implementation modules private by default and make
  `__init__.py` re-exports intentional. Put shared contracts in a leaf rather
  than resolving an import cycle with late imports.
- **Racket:** give each module a narrow `provide` surface and keep mutable
  ownership in one module rather than mirroring it across adapters.
- **UI and styles:** split by component or visual responsibility. Preserve
  cascade and layer order explicitly. A section heading is a candidate seam,
  not proof of one.
- **Tests:** move complete scenario families beside their subject or into
  subject-named test modules. A thin aggregate may import them when the build
  expects one root, but it may not hide omitted scenarios or duplicate fixtures.
- **Build and tooling:** extract declarative inventories and subject-specific
  helpers behind narrow functions. The root build file should compose steps,
  not own every language's implementation details.

Delete migration scaffolding once callers move. Compatibility aliases,
catch-all re-exports, duplicated constants, and old and new paths kept alive
together leave a split incomplete unless a supported consumer requires them.

## Work sequence

1. Measure the file. Split only files the task opens, because a drive-by split
   of an untouched large file is scope creep.
2. Map the ownership seam and dependency direction. Read the callers whose
   lifetime, visibility, or generated contract could change.
3. Extract one complete subject. Move tests or add focused evidence that proves
   the new boundary, then remove dead imports, exports, aliases, comments, and
   duplicated logic exposed by the move.
4. Make the intended change once the file has room for it.
5. Run the narrow language or subsystem checks, then `zig build source-check`.
   Substantial structural work finishes with `zig build check` per the
   [work skill](../work/SKILL.md).
6. Review the diff cold: each new module has one nameable owner, dependencies
   point one way, the original file is simpler rather than merely shorter, and
   no evidence or failure path disappeared in transit.

## Handoff

Report the old and new line counts, the ownership seam created, and the checks
that passed. If the correct extraction cannot fit the current task, leave the
additive work undone rather than crossing the limit.
