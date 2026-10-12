---
name: file-budget
description: >-
  Use when source-check reports a file-length violation, when any change
  touches an exception in tools/check/source_check/file_length.zig, or when a
  first-party source approaches 650 lines. This is the canonical procedure
  for shrinking the closed exception inventory to empty. Not for an unrelated
  one-line edit in a file below budget (work) or a structural pass whose
  purpose is not file size (smell-annihilation).
---

# File budget — retire the exceptions

First-party source files stop at 650 lines. The rows in
[`file_length.zig`](../../../tools/check/source_check/file_length.zig) record
inherited debt at their current sizes. They are not waivers, and the inventory
is closed: **never add a file, raise a ceiling, or replace a removed row.** The
table may only lower a ceiling, reorder lowered rows to stay largest-first, or
lose a row.

The destination is an empty exception table. A successful split moves a whole
subject behind a named module boundary and leaves both sides easier to change.
Moving lines without moving ownership pays no debt.

## The ratchet

- A file outside the exception table never finishes above 650 lines. Split it
  before the change crosses the limit. Never add an exception.
- An exception file never finishes longer than its recorded ceiling.
- Any change that adds behavior, declarations, scenarios, or documentation to
  an exception file must make space first by extracting or simplifying more
  than it adds. The final file must be strictly shorter than it was, and the
  same change lowers its ceiling to the exact final line count.
- A non-additive correction may leave an exception file at its current ceiling
  but may not use the debt as headroom.
- Any shrink, even an incidental one-line deletion, lowers the ceiling in the
  same change. At 650 lines or fewer, delete the row instead.

Do not game the count. Minifying, combining independent statements, deleting
useful comments or evidence, weakening formatting, moving source under an
ignored/generated/vendor path, or creating `part1`, `misc`, `helpers`, or
`common` dumping grounds turns visible debt into harder debt. Fix generated
output at its generator, and never hand-edit or hide it.

## Choose the seam before moving lines

Read the file's structure and say what it owns in one sentence. Inventory its
state, public entry points, imports, callers, and tests. A strong extraction
candidate has at least one of these boundaries:

- one authority over a table, lifecycle, or mutable state;
- one protocol operation or state-machine arm with its own invariants;
- one transport, binding projection, UI surface, build concern, or scenario
  family;
- a leaf vocabulary used by several siblings but owned by none of them;
- a section that changes and can be tested independently of its current file.

Prefer the smallest complete subject that gives dependencies one direction.
Move its state and invariants with its operations. If the old file still owns
the state while the new file manipulates it through a wide helper surface, the
boundary is cosmetic. If two proposed modules must import each other, extract
their shared contract as a narrower leaf or choose a different owner. Each
extracted file stays below 650 lines and owns one nameable subject.

Write the before-and-after shape before editing. For example: “the driver loop
owns admission and TCP provider policy” becomes “the loop owns admission;
`tcp_provider` owns TCP lifecycle and exposes one narrow outcome contract.” If
the second sentence is not clearer, the proposed split is not ready.

## Extraction shapes that hold up

Use the language's ordinary module mechanism, and reach for a subdirectory as
readily as a sibling file. A split that leaves four `subject_*` files beside
forty others flattens structure the names already carried. When the pieces of
one subject share a prefix, share a harness, or would be read together, give
the subject a directory and drop the prefix from the names inside it
(`c_abi/host/close_test.zig`, not `c_abi/host_close_test.zig`). The directory
is then the subject's one home: its shared fixtures live inside it, not in a
global support pool, and the next split of the subject has an obvious place to
land. Rooms did this with `net/`, `store/`, and `test/page/`.

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
  cascade/layer order explicitly; a section heading is a candidate seam, not
  proof by itself.
- **Tests:** move complete scenario families beside their subject or into
  subject-named test modules. A thin aggregate may import them when the build
  expects one root, but it may not hide omitted scenarios or duplicate fixtures.
- **Build and tooling:** extract declarative inventories and subject-specific
  helpers behind narrow functions. The root build file should compose steps,
  not own every language's implementation details.

Delete migration scaffolding once callers move. Compatibility aliases,
catch-all re-exports, duplicated constants, and old/new paths kept alive
together leave a split incomplete unless a supported consumer requires them.

## Work sequence

1. Measure the starting file and find its exact exception row. For planned
   work, choose the largest row whose subject you can improve; when a task
   already touches an exception file, pay down that file instead of adding to
   it. Split only files a task opens. A drive-by split of an untouched large
   file is scope creep.
2. Map the ownership seam and dependency direction. Read the callers whose
   lifetime, visibility, or generated contract could change.
3. Extract one complete subject. Move tests or add focused evidence that proves
   the new boundary, then remove dead imports, exports, aliases, comments, and
   duplicated logic exposed by the move.
4. Make the intended change only after the oversized file has enough real
   responsibility removed that its final count will be below the old ceiling.
5. Format, measure every affected file, and set the exception ceiling to the
   exact final count. Reorder the table largest-first, or remove the row at the
   project limit.
6. Run the narrow language or subsystem checks, then `zig build source-check`.
   Substantial structural work finishes with `zig build check` per the
   [work skill](../work/SKILL.md).
7. Review the diff cold: each new module has one nameable owner, dependencies
   point one way, the original file is simpler rather than merely shorter, and
   no evidence or failure path disappeared in transit.

## Handoff

Report the old and new line counts, the ceiling lowered or row removed, the
ownership seam created, and the checks that passed. “Added an exception” is
never a valid outcome. If the correct extraction cannot fit the current task,
keep the file from growing and leave the additive work undone.
