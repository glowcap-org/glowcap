---
id: ADR-0085
status: accepted
date: 2026-07-16
tags: [repository, apps, tools, cli, layout]
decision: "Product binaries live under cli/ and apps/; demos under examples/apps/; the dev-tool verbs are test/ (top-level), tools/check/, and tools/gen/, with tools/c-abi/ for the C-ABI operator toolkit. tools/ never hosts product apps."
supersedes: []
superseded_by: []
---

# ADR-0085 repository product and dev-tool layout

## Context

`tools/` had become a flat dump of gates, generators, and operator scripts, and
the name invited dumping first-party product apps (for example ocapnviz) beside
maintainer codegen. `cli/` already owns the installable `pancake` binary
([ADR-0084](ADR-0084-pancake-cli-product-boundary.md)); `examples/apps/` owns
demos. There was no honest home for a major in-tree product that is neither the
CLI nor a showcase. The usual maintainer verbs (`test`, `check`, `gen`) were
not visible as peer families.

## Decision

1. **Product binaries** live under `cli/` (the `pancake` binary) and top-level
   `apps/` (first-party apps with their own binaries, such as ocapnviz). They
   consume the public `pancake` module and are not part of `libpancake_*`.
2. **Demos** stay under `examples/apps/`. They teach and dogfood; they are not
   the shipping product surface.
3. **Dev-tool verbs:**
   - `test/`: correctness scenarios (already top-level; not nested under
     `tools/`).
   - `tools/check/`: gates and hygiene (`arch_check`, `meta_check`).
   - `tools/gen/`: codegen that must stay in lockstep with `src/`, headers,
     and bindings, plus a shared verify/emit harness.
   - `tools/c-abi/`: operator scripts and JSON oracles for the publishable
     C-ABI resolve path ([ADR-0077](ADR-0077-publishable-c-abi-resolve.md)).
4. **`tools/` never hosts product apps.** A reader who wants ocapnviz looks in
   `apps/`, not under maintainer codegen.

## Scope (what this does not decide)

- Whether ocapnviz ships, its event schema, or its packaging.
- Splitting `tools/check/meta_check.zig` into smaller modules.
- Renaming the capability showcase at `examples/apps/tools/`.

## Alternatives Considered

- **Product apps under `tools/ocapnviz/`.** Rejected: conflates maintainer
  codegen with first-party products; the flat `tools/` dump is the failure mode
  this ADR closes.
- **Rename `tools/` to `codegen/` and leave gates at the root.** Rejected: check
  and gen are the same kind of maintainer family; keeping the widely cited
  `tools/` name with peer children is enough once apps leave.
- **Move `test/` under `tools/test/`.** Rejected: `test/` is already the
  established top-level verb and gate surface.

## Consequences

- `apps/README.md` and `tools/README.md` state the contracts.
- Living-state docs and the CLI design layout table name the axes.
- Generator path citations move under `tools/gen/`; C-ABI operator paths under
  `tools/c-abi/`; gate imports become `tools/check/*`.
- Adding a generator is one `tools/gen/` module plus one `build.zig` table row
  that drives the shared verify/emit harness.
