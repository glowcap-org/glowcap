---
id: ADR-0080
status: accepted
date: 2026-07-13
tags: [session, codec, references, taste]
decision: "The session models near-export, far-import, promise, and answer as one versioned Slot whose wire descriptor is a projection of its (mint, binding) state, computed at render and never stored."
supersedes: []
superseded_by: []
---

# ADR-0080 Unified reference slot

## Context

CapTP names four reference kinds: a near export (a capability this vat hosts), a
far import (a capability a partner hosts), a promise (a value not yet known), and
an answer (the settled result of a pipelined call). Every implementation, Goblins
included, and glowcap today, carries these as four tables. `ExportTable`,
`ImportTable`, `SlotTable`, `AnswerTable`: with four sets of GC, resolution, and
pipelining rules. The special cases multiply: pipelining is a separate path,
resolution is written per kind, three-party handoff re-derives references from
scratch.

The kinds are not four things. They are one thing seen from two axes: who minted
the position, and what it currently binds. That collapse engages three First
Principles directly. "Session state is authoritative; codecs parse and render
but do not own authority," "make illegal states unrepresentable," and the taste
rule that a special case is a smell. The evidence is the wire itself: the four
`desc:*` descriptors are not independent, they are a function of those two axes.

## Decision

The session tracks one `Slot` primitive, keyed `(session, slot_id)`. A slot's
identity is not a kind but two fields:

- `mint`. `local` or `remote`: who allocated the position.
- `binding`. `unresolved`, `value`, or `broken`: what it currently names.

The four wire descriptors are a pure projection of the legal `(mint, binding)`
variants, computed when the codec renders and never stored:

- local + unresolved becomes a promise this vat made
- remote + unresolved becomes an answer this vat awaits
- local + value becomes a near export
- remote + value becomes a far import
- (either) + broken becomes a broken reference

The legal states are a **sum type**, not a validated product, so an impossible
combination cannot be constructed. Pipelining becomes an ordinary deliver to an
unresolved slot; resolution is one state transition; three-party handoff re-homes
a slot to a new session; distributed GC is one refcount story over one table.
`src/ocapn/session/` owns the slot table and its transitions; `src/ocapn/codec/`
owns the projection at render. The wire keeps its four `desc:*` descriptors and
their exact bytes: the collapse is internal.

## Scope (what this does not decide)

The wire format does not change: the four descriptors and their bytes are fixed
by conformance. This does not touch the Cap'n Proto codec's reserved slot beyond
the same projection seam. It does not fold in the swissnum / bootstrap registry,
which is a name-to-capability map, not a position-keyed slot table. A big-bang rewrite of every live table in one change is rejected. CapTP keeps
three position namespaces (export, import, answer); the sum type is shared, but
one physical map must not conflate them. Answer rows carry a `Slot` binding;
export and import rows carry `Slot` + wire-delta count in their own tables.

## Alternatives Considered

- **Keep four tables (status quo)**: four rule-sets, and the pipelining,
  resolution, GC, and handoff special cases stay multiplied. Rejected because it
  contradicts "the session is authority, the codec only projects": today the
  codec's descriptor choice is treated as identity.
- **One table with a 4-way `enum { export, import, promise, answer }` tag**:
  rejected because it reintroduces the four kinds as a stored tag. The kind is
  derivable from `(mint, binding)`, so storing it is storing a projection.
- **Store `(mint, binding)` as a product and validate**: rejected because nonsense
  cells become representable and must be checked at runtime; a sum of the legal
  variants makes them uncompilable.

## Consequences

`src/ocapn/session/` collapses `SlotTable` / `AnswerTable` / `ExportTable` /
`ImportTable` onto one slot table; the codec gains a projection
`descriptor(slot)` to `desc:*`. GC, pipelining, resolution, and handoff each shrink
to a single code path. The acceptance gate is conformance byte-identity: `zig
build oracle-check` and the live goblins interop must produce byte-identical
frames before and after, because the collapse is internal only: a single moved
descriptor byte is a failure, not a success. An arch-gate rule can assert the
descriptor is only ever projected, never stored on a slot.

## Forward compatibility

The projection is the one seam where a future wire-profile change plugs in: a new
descriptor is a new arm mapping a `(mint, binding)` variant to bytes, not a new
table. The Cap'n Proto codec reaches the same slot through the same projection.

## Notes

Builds on ADR-0079 (CapTP vocabulary). The session-authority and
codec-projection boundary is stated in `docs/architecture.md`.

## Amendment (2026-07-13): realized shape

The `Slot` sum (`src/ocapn/session/slot.zig`) is the shared `(mint, binding)`
primitive, and the export / import / answer tables each carry `Slot` cells in
their own position-keyed table, not one conflated map, per the Scope section.
That is the accepted shape.

**What landed.** Engine-internal promise exports are minted authoritative as
`local_unresolved` at allocation (`Session.allocatePromiseExport`), and render
sites project via `slot.toReference` instead of hand-typing a kind. V1.0
`resolve-me-desc` callbacks, including bootstrap fetch, are resolver *objects*
and therefore mint ordinary local-object slots through `Session.allocateExport`.
With that,
`retainSentExportRef`'s already-live branch reduced to pure retain and its dead
cell reconciliation (`ExportTable.bind` / `fulfill` / `breakSlot`,
`SlotTable.setCell`) was deleted. `zig build oracle-check` held byte-identical
throughout.

**The projection seam is the session, not the codec.** The syrup encoder has no
`Session` (`writePayloadReference` takes a sink and a `model.Reference`), so the
projection lives at the session's render sites: they project `Slot` to
`model.Reference` and the codec renders its bytes unchanged. `model.Reference`
stays the codec interface.

**The boundary: an app near reference's wire kind is app-authoritative.** A
`near` reference carries its object/promise distinction on the reference itself,
as the C-ABI `sub_kind` (across all five bindings, the generated header, and
`gen-ts-abi`). An application legitimately mints an export generically and names
it `near-promise` per reference; those wire bytes come from the app-supplied
`near.kind`, not the row's cell. Deriving the kind from the row would mean
removing `sub_kind` from every near reference across the whole C ABI: a
wire/ABI-contract change, not the internal collapse this ADR scopes. So
`retainSentExportRef`'s fresh/first-mint branch reads `near.kind` as the only
authority for an absent row, the engine-internal promise exports the session owns
are authoritative and projected, and the app-facing near kind stays authoritative
at the reference. That split is the close.
