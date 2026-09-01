---
id: ADR-0129
status: accepted
date: 2026-08-25
tags: [rooms, capabilities, persistence, browser, identity]
decision: "A Rooms personal archive is one ordinary OCapN object with `put` and `read`: recorders upsert bounded standing or line records under opaque source and conversation-generation identities, and readers consume a bounded revision feed whose records retain those coordinates. A tab hosts this object over its IndexedDB database; nicknames and fresh session keys remain context, never merge authority or durable identity."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0130, ADR-0132, ADR-0133, ADR-0135, ADR-0136, ADR-0140]
---

# ADR-0129 Member-owned archive capability

## Context

Rooms already has two persistence policies. A directory may retain a bounded
tail of public-room lines, and a browser may keep bounded direct-message text
on that device. Neither is a separately passable authority, and a directory
nickname cannot identify the same person or conversation after its holder
leaves. Making the browser store shareable therefore decides an application
protocol, an identity boundary, update semantics, and a resource bound at once.

The decision engages the principles that session state is authoritative,
capabilities carry authority, and attacker-controlled inputs are bounded at
the receiving edge. [`docs/planning/rooms-persistence.md`](../../planning/rooms-persistence.md)
names the product reads this contract serves; this record fixes the first
shippable capability shape.

## Decision

A personal archive is one ordinary OCapN object with exactly two verbs:
`put(record)` and `read(filter, afterRevision, limit)`.

`put` accepts one bounded record and replaces the prior record with the same
key. A record is either a standing (directory, room, and nickname) or a line
(room or direct conversation, sender, text, local direction, time, and
present/edited/withdrawn state). The key always contains an opaque recorder
source, an opaque conversation generation, and an opaque record identifier.
An update receives a new archive revision. A withdrawal replaces its text with
the empty string, so the archive does not preserve plaintext behind a visible
takedown.

`read` accepts optional exact filters for source, generation, record kind,
conversation kind, directory, and conversation. It returns records with revisions greater than the supplied
cursor, ordered by revision and capped by both the caller's request and the
protocol maximum. Its answer carries the next revision cursor and whether
another matching page was present. A record updated after a reader saw it
therefore appears again under its same key; a reader applies the greater
revision. The archive has a hard total-record ceiling and evicts the least
recently revised records, so neither writes nor reads grow without limit.

The recorder mints and retains its source identity and mints a fresh
conversation generation for each live conversation it records. Those values
are correlation coordinates, not person identities. A nickname, an
unauthenticated locator claim, and a fresh CapTP session key may be carried as
context but never select or merge a generation. Every read returns source and
generation explicitly, so recovered records cannot enter a live conversation
as an unmarked continuation.

The browser implementation owns the `rooms-history` IndexedDB database. It
hosts the same behavior on any live session when the tab chooses to pass the
archive reference. The project is prerelease: a database from an older schema
is reset, not translated or retained behind a compatibility view. Every row
the application can read therefore carries the source and generation the
archive contract requires; none receives invented provenance.

## Scope (what this does not decide)

- Attachment metadata and bounded blob custody are retained per ADR-0136. Blob
  readers remain separate capabilities rather than values in history pages.
- An archive peer with a durable locator is not implemented by this decision.
- Narrowed and read-only facets, revocation, and the interface for handing one
  to another member are not implemented by this decision. The fixed two-verb
  object makes those facets ordinary forwarding capabilities rather than a
  second storage protocol.
- Evidence from an authenticated durable transport identity is not stored yet.
  Adding it must remain optional evidence on a generation, never its key.
- Reads report one archive's account. Coalescing several sources is a
  presentation choice and never rewrites their keys.

## Alternatives Considered

- **Key direct history by directory and nickname**: rejected because a
  directory may grant the nickname to a different holder; it is context, not
  durable identity.
- **Append immutable edit and withdrawal events**: rejected because retaining
  the earlier plaintext after withdrawal breaks the existing takedown promise.
- **Return an unbounded snapshot**: rejected because holding a capability does
  not grant authority to exhaust its host's memory or one wire turn.
- **Add separate methods for standing, rooms, and direct messages**: rejected
  because those are record kinds and filters over one authority, not three
  storage systems.
- **Make history a directory method**: rejected because direct messages never
  traverse the directory and two members in one room may intentionally keep
  different records.

## Consequences

`apps/rooms/lib/archive/protocol.ts` owns the application record vocabulary, bounds,
parsing, behavior, and client. The tab's IndexedDB adapter owns durable source
and revision allocation. The direct-message recorder owns conversation
generation and record IDs; the presentation layer may read older contextual
rows, but it must label their source and attribution limits.

The later read-only facet is an attenuator that forwards only `read`. A scoped
facet additionally intersects every requested filter with the scope it closes
over. Neither changes this wire contract.

## Evidence and gate

`apps/rooms/test/archive/protocol_test.ts` proves validation, idempotent replacement,
withdrawal erasure, revision resumption, source/generation separation, and
both read and storage ceilings against an in-memory implementation of the same
backend contract. `apps/rooms/test/archive/wire_test.ts` fetches and uses the
same object over the Goblins-compatible v1/Syrup floor. `zig build
rooms-web-dm-tabs` proves the IndexedDB-backed tab
continues to record, edit, withdraw, and hydrate direct lines. `zig build
rooms-server-test`, `zig build source-check`, and `zig build check` gate the
application contract and repository integration.

## Notes

Related: [ADR-0128](ADR-0128-room-links-peering-and-irc-edges.md) for the
directory and direct-message identities this archive records without
strengthening.
