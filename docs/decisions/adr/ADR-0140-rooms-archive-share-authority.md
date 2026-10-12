---
id: ADR-0140
status: accepted
date: 2026-08-29
tags: [rooms, capabilities, persistence, handoff, security]
decision: "Archive sharing is person-to-person over a live DM whose facet scope is independent of that pipe. Live handover names directory, record kind, and conversation, remains one-shot, and dies with its session. Independently revocable durable offers are Host publications from the archive peer's own share ledger. A digest is a filter dimension that authorizes blob(digest) only inside the facet's scope."
supersedes: []
superseded_by: []
amends: [ADR-0129, ADR-0130, ADR-0132, ADR-0136]
amended_by: []
---

# ADR-0140 Rooms archive share authority

## Context

ADR-0132 ships read-only handover for one direct conversation. A room does not
have a past. People do. Broadcasting a room's archive into the room would
confuse live membership with one member's account. Session-lifetime facets are
not revocation. ADR-0136's content digest identifies bytes. It is not a
lookup key on the whole archive.

The protocol distinguishes live `handRoom` from durable `offerRoom`, and
ADR-0137 provides independently revocable Host publications with a tombstoned
ledger and HMAC-derived entropy. Archive sharing needs both shapes.

## Decision

Handover stays person-to-person on a live direct session. The facet's filter is
not that DM's identity.

Live `handArchive(directory, kind, conversation, archive)` takes
`kind` in `direct`, `room`, or `standing`. `conversation` is the archive
coordinate for that kind, or `null` only for directory-wide standing. The
capability is last. The receiving tab still `ensureDm`s the pipe, still keeps
at most 16 live occurrences, and still requires one-shot read or give-back.
It validates the live directory. Direct shares still require a conversation
string. Room and standing shares do not require that string to equal the
pipe's persistId, do not mint a fake joined room, and land attributed records
on the transport DM. Standing records never become live roster state.

Durable `offerArchive(directory, kind, conversation, sturdyref)` is data, the
archive sibling of `offerRoom`. Only a standalone archive peer may mint the
sturdyref. The sender confirms the carrying DM before that mint. A failed
offer tombstones the share it just published. The peer keeps `shares.json`
beside `peer.json`: client-minted UUID,
label, exact filter, and revoked tombstones, with the same persist-then-publish
and tombstone-then-unpublish order as ADR-0137. Entropy is HMAC-SHA-256 of a
domain-separated share id and canonical filter, keyed by the archive root
publication entropy. `share` and `revokeShare` succeed only on the whole
read-write root. `narrow` does not copy that issuer. A browser IndexedDB
archive refuses durable mint with that sentence. It does not substitute a live
facet.

The archive filter adds `digest`, a 64-character SHA-256 hex or `null`, as a
seventh exact dimension. A line matches when some retained `attachment.blob`
equals that digest. A standing record and a digest never intersect.
`blob(digest)` mints a byte reader only when the facet's current scope includes
a line that names that digest. Callers still cannot select an arbitrary blob
from a wider archive than they hold.

Room-card share names a directory member, ensures a DM with them without
stealing the reader's selection, and hands a facet scoped to that room's
archive coordinate. Standing share uses `kind: standing` for the same room.
The DM card still shares that DM.

## Scope (what this does not decide)

ADR-0144 settles the combination of several archive accounts into one
evidence-backed view. This does not add a global content-addressed blob
index, a room-broadcast archive, or durable minting in the tab recorder.

## Alternatives considered

- **Same button on the room card, posting into the room.** Rejected because a
  room is not an account of its own past. Handover is person-to-person.
- **Smuggling kind through the conversation string.** Rejected because kind is
  its own exact dimension and empty or encoded sentinels are a second parser.
- **Revocable live facets.** Rejected because a live occurrence dies with its
  session. Independent revocation needs a Host publication and a tombstone.
- **Lookup-any-blob-by-hash on the whole archive.** Rejected because a digest
  is data. Authority stays the facet's filter, including an optional digest
  dimension.

## Consequences

Live and durable archive offers are different objects. Mixing them would hide
revocation inside session lifetime. Hash-addressed file homes are digest-narrowed
facets, handed live or published as durable shares.

## Evidence and gate

`apps/rooms/test/archive/protocol_test.ts` holds digest intersection and the tab's
durable-mint refusal. `apps/rooms/test/archive/wire_test.ts` holds scoped
`blob(digest)`. Native session-service scenarios hold live admission and drive
the four-argument live and durable verbs through the peer. A failed
durable offer revokes the share it just minted. A session room share realizes
the carrying DM the same way a session `say` does, without dialing intended
directs on restore. An attached room-card share starts that DM without stealing
selection. Rust runtime tests hold persist-then-publish, serialized listing
across that publication, and tombstone-then-unpublish.
`apps/rooms/test/archive/peer_test.ts` redeems and revokes a durable share
across process restart.
The native session-service live-operation scenario holds the four-argument live
verb and data-only `offerArchive`. `zig build rooms-web-archive` still drives
the direct-line one-shot path.

## Notes

Amends ADR-0132 (live DM-only handover), ADR-0136 (digest is not authority),
ADR-0129 (filter tuple), and ADR-0130 (the root swiss is not the only
durable publication).
