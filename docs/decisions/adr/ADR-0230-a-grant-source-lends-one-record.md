---
id: ADR-0230
status: accepted
date: 2026-10-14
tags: [loam, access, memory, grants]
decision: "A grant source owns the storage of every record it returns and lends one record at a time. The grant view refuses a lookup while a loan is open, in every build mode, and a caller that needs a record past the next lookup copies the fields it needs before releasing."
supersedes: []
superseded_by: []
amends: [ADR-0166, ADR-0167]
amended_by: []
---

# ADR-0230 A grant source lends one record

## Context

ADR-0166 gave `access.core.GrantView` a synchronous source contract and
returned each grant record by value. The record's two scope selections
borrowed the source, and the storage source decoded every grant into one
fixed scratch, so a returned record was valid "until the next grant lookup".
Nothing enforced that sentence. A caller that held a record across a second
lookup read overwritten selections and no test or build mode could tell.
Three storage paths dodged the hazard by hand: staging decoded the prior row
again into a second 16 KiB stack scratch, observation decoded every ancestor
again on the heap, and the inventory took the scratch while a copied record
was still in use. Profiling the Loam hot-read bench ranked the by-value copy
of an 896-byte record per ancestry step as the largest remaining cost in
`memcpy`, and the storage source cached only grants whose scopes needed no
selection.

## Decision

A source lends. `GrantView.Source` carries a `lend` function that returns a
pointer to a source-owned record and an optional `release` function that
ends the loan. `GrantView.borrow` returns that pointer and `release` returns
it, and `Ancestry.next` releases the previous step's record before borrowing
the next, with `close` for a walk that stops early. The view refuses a
lookup while it holds a loan with `error.RecordHeld`, a member of
`SourceError` that stays on under every optimization mode, because a stale
borrow is a stale authority verdict. A source with shared storage refuses the
same way: `access.storage.Read` keeps one decoded `GrantRecord` beside its
selection scratch, sets a held flag when it lends, and refuses both a lookup
and `grantScratch` until the release. `Read.heldRow` exposes the stamps and
child root of the row behind the open loan, so staging, observation, append,
and history stamps read them without a second decode. The ledger's rows are
stable, so its source declares no `release` and the view alone refuses
reentrant lookups.

`GrantPlan.changes` keeps an edit's current row on loan and says so with
`Changes.borrowed`. The caller releases it through `Changes.release` once the
record is encoded. The parent's inventory update is copied out as
`Changes.Parent` while its own loan is open, so no second record is ever
outstanding. Storage operations that disclose a grant copy its scalars into
`storage.InspectedGrant` during one ancestry walk that proves containment and
folds in every status on the path.

The ledger stores `Record` rows directly and lends `&records[slot]`. The
separate entry type and the function that rebuilt a record from it are gone.
`Terms.initCopying` and `Terms.deinitOwned` own the selection copy, and
`StoredTerms` remains the marker for a field that owns its selection.

## Scope (what this does not decide)

`ResourceView` keeps returning its 40-byte record by value. It borrows
nothing, so a loan would add ceremony and remove no hazard. The ledger's
`get` still returns a copy whose selections borrow the ledger until its next
commit, which is the volatile model's documented contract.

## Alternatives Considered

- **A debug-only lookup stamp on the returned record**: a stale read would
  trap only in Debug and ReleaseSafe. Rejected because a hidden alias in
  ReleaseFast is the case that matters.
- **Callback-scoped access**, where the source runs a caller closure over the
  record: still needs the held flag for the storage scratch and nests every
  consumer. Rejected as the same guarantee at a higher syntax cost.
- **A view-owned record slot** copied on every lookup: ties the lifetime to the
  view instead of the real owner and keeps the copy the profile ranked.
- **Keeping the 20 KiB read budget** by overlaying the decoded row on the
  selection scratch: a maximal grant then has no room for its selections.
  The read budget moves to 21 KiB and the row costs under 1 KiB, against a
  16 KiB stack scratch and the heap decodes it retires.

## Consequences

- `src/loam/access/core/grant_view.zig` owns the loan. Every consumer in
  `src/loam/access/storage` borrows and releases, or walks an ancestry with
  `defer path.close()`.
- `src/loam/access/storage/read.zig` caches the last committed decode for
  every scope shape, not only scalar ones, because the row and its selections
  now survive together until the next decode.
- `src/loam/access/storage/inspected_grant.zig` is the one portrait a held
  control discloses, and `GrantInventory.Item` is that type.
- `test/loam/access/grant_view_test.zig` counts loans and releases in its
  source, so an evaluation path that leaks a loan fails there.
- `core.Policy.Value` carries its sixteen limits as plain unsigned words
  beside a `bound_mask`, the pair `GlowcapLoamPolicyValue` already exposes,
  instead of sixteen optional words. A clear bit holds zero, so equal values
  are equal bytes and `validate` refuses a nonzero slot the mask does not
  claim. The record grammar is unchanged: an unbounded slot still encodes as
  `f`. A value is 160 bytes instead of 288, and a grant record 640 instead of
  896, which keeps the operation state inside 40 KiB.

## Evidence and gate

`zig build test -Dtest-layer=loam` covers the view, the ledger, and every
storage consumer. The grant view test proves the refusal, the early-exit
close, and that a record the view rejects as malformed is returned. The owner
test proves that a second view, the same view, and the selection scratch all
refuse while a record is on loan, and holds the read budget at 21 KiB.
`zig build profile-loam -- --tasks-only --smoke` reads the hot-read cost.

## Notes

Amends ADR-0166 (the borrow sentence and the entry type) and ADR-0167 (the
20 KiB read budget). ADR-0171's shared effective-policy calculation now
intersects each borrowed record's pair in place instead of copying terms.
