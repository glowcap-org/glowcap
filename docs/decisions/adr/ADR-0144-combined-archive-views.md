---
id: ADR-0144
status: accepted
date: 2026-09-05
tags: [rooms, capabilities, persistence, browser]
decision: "A Rooms reader holding several archives reads them as one combined account per conversation: every held archive answers, records coalesce by their recorder coordinates, the winner carries its keeper for attribution, and re-reads revise the standing view in place. Writes stay exclusive to the selected recorder; the combination is read-side only."
supersedes: []
superseded_by: []
amends: [ADR-0131]
amended_by: []
---

# ADR-0144 Combined archive views

## Context

ADR-0129 through ADR-0133 and ADR-0140 built the member-owned archive: one
object, scoped facets, a standalone peer, and handover. Every one of them
deferred the same sentence: combining several archive accounts into one
evidence-backed view remains a presentation decision.

The gap was concrete. Writes are exclusive to the selected recorder
(ADR-0131), so a member who selects an archive peer after keeping device
history — or whose durable session wrote to its local backend before a peer
answered — owns records in two archives under one set of coordinates, and no
read could show both. A line edited after the selection change lived under the
same key in both archives with different content. And a re-read of a kept
share prepended a second copy, because the store gave shared accounts no
identity to reconcile by.

ADR-0131 rejected exactly this combination as a *write* fallback: "one visible
recorder conceals two authorities." That rejection stands for writes. The read
side is what it said was missing — a merge policy — and this is it.

## Decision

Reading combines; writing never does. When a reader holds more than one
archive, a history read asks each of them — the browser's device store beside
a selected peer, the durable session's local backend beside its held peer —
and `apps/rooms/lib/archive/merge.ts` coalesces the answers:

1. Identity is the record's coordinates (`archiveRecordKey`). Two accounts
   reporting one key are one account stored twice, never two records. No key
   is rewritten and no record leaves its recorder's source.
2. Lifecycle state ranks: withdrawal outranks edit outranks present. The
   lifecycle is monotone, so the higher state is never the stale one. This is
   the case that matters: a line edited after a selection change shows its
   edit, whichever archive received it.
3. A remaining tie — same key, same state, different content — cannot be
   ordered locally, and the rule says so rather than pretending otherwise:
   the account currently selected for writes wins, as the holder of the
   member's most recent intent; with no write target in the set, the first
   listed account wins, keeping the answer deterministic.

Absence is not a verdict: a key missing from a re-read means eviction, not
withdrawal, and removes nothing. Attribution is presentation: each account
generation stands under a divider naming every keeper that contributed to it,
and a combined account never draws as live traffic. An unavailable selected
peer still refuses writes and reports itself, but no longer hides the device
store's existing records — reading what this browser already kept is not the
fallback ADR-0131 forbade. This amends ADR-0131's read posture only.

In the store, archive items carry their coordinates, and a re-read revises in
place through `insertArchiveLines` / `reviseItem`
(`apps/rooms/web/ui/store/items.ts`): edits replace, withdrawals empty, new
lines join their account's section, and the revision never reaches the line
recorder, so reading somebody's account cannot write it into the reader's own
archive (ADR-0132's rejection of copying stands). The room's own retained tail
stays a prefix block: the room protocol supplies no durable line identity, so
there is nothing to reconcile by (ADR-0133).

Sections use full source and generation coordinates as identity, independently
of the divider's abbreviated display text. New rows join their section in time
order, and standing updates revise its divider. Initial reads preserve edit
state. File views retain the content digest so successive refiles replace
custody even when names and sizes stay the same; unchanged reads preserve the
drawn row and loaded file URLs.

## Scope (what this does not decide)

No storage migrates between archives, and no archive copies another's records;
the combination exists only at the reader. There is no source-picker
interface: the reader chooses accounts by reading or discarding each offered
share, and attribution dividers name what is standing. The shared-account blob
posture is unchanged — a shared line's attachment bytes stay behind the
sharing member's facet. Server-side room retention is untouched: it is the
room's own account, coordinate-less by design.

## Alternatives considered

- **Migrating device history into the peer at selection.** Rejected by
  ADR-0131 for its duplication and provenance semantics; the combined read
  answers the same need without moving anything.
- **Chronological interleave of archive rows with live traffic.** The attached
  session's own-archive reconcile already works that way, but for accounts
  from *other* members a divider-scoped section is what keeps "not live
  traffic" legible line by line; sections keep that guarantee.
- **Per-line keeper marks.** Rejected as weight the interface does not need:
  the section divider names the account, and a line never leaves its section.
- **Treating a key absent from a re-read as deleted.** Rejected: eviction is
  not a withdrawal, and only the withdrawn state may empty a line.

## Consequences

`DurableRoomsArchive.read` (session side) and `readLines` (page side) both
answer the merged account, so standalone and attached views tell the same
story. The device store is consulted through a permanent slot lease that
survives selection changes. Page reads retain each winning record's source
slot; durable-session reads resolve the record's exact content digest among the
archives still held, using the selected peer's digest lookup before consulting
the local blob store. An already-issued wire reader refuses if that file
position names different bytes; metadata-only changes preserve byte authority.
ADR-0131's Evidence section's "refusal without device fallback" claim now names
writes only. The "combining remains open" deferrals
in ADR-0132, ADR-0140, and the rooms-persistence plan are closed by this
decision.

## Evidence and gate

`apps/rooms/test/archive/merge_test.ts` proves the coalescing rule: disjoint
accounts contribute, one key never doubles, lifecycle rank outranks, the write
target breaks content ties, and two recorder sources never merge.
`apps/rooms/test/archive/target_test.ts` proves the page seam: a split
generation shows once under both keepers, an unavailable peer leaves the
device account standing, and per-line attachment reads stay bound to their
origin archive across a target swap. Native session-service archive scenarios
prove that a durable session reads received live history through the actual
peer while retaining its session-owned archive.
The Syrup-floor archive scenario in `apps/rooms/test/archive/wire_test.ts`
proves a file reader cannot retarget when its line is replaced and continues
reading unchanged bytes after a metadata revision.
`apps/rooms/test/store/archive_sections_test.ts` proves a re-read shared account
revises file metadata and chronological sections without doubling lines or
dividers. `apps/rooms/test/attached/archive_projection_test.ts` checks digest
replacement, object-URL cleanup, unchanged custody, and recovery without
archive writes. `zig build rooms-web-archive` drives the browser proof: a
conversation generation split across the device store and the iroh peer reads
back as one account under both keepers, and a fresh profile holding only the
peer sees only its account.
