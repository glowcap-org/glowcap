---
id: ADR-0126
status: accepted
date: 2026-08-25
tags: [rooms, capabilities, sturdyrefs, moderation, persistence]
decision: "Each room may issue one durable steward sturdyref to its opening connection. Later holders take it explicitly, validate it against a non-authority room identity, and never inherit it from a nickname, rank, or reconnect order."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0127]
---

# ADR-0126 Durable room stewardship

## Context

A live steward reference given to the opening connection ends with the session.
A restart then leaves no moderator, and granting the first connection back lets
arrival order seize an existing room. Nicknames cannot fix this because they are
temporary claims that another person may later hold.

The room's durable link supplies the identity boundary. The steward must
survive for the same room without becoming room-entry authority, and taking a
shared steward must fail closed when it belongs to another room.

## Decision

Each room can issue one durable steward publication. Only the connection that
opened the live room generation can cause the first issuance. The server records
issuance before answering and derives the room and steward swiss names from
separate HMAC domains. After issuance, a reconstructed room grants no
stewardship to the first subscriber. A holder returns by enlivening the steward
sturdyref.

The steward answers `governs` with a domain-separated SHA-256 identity of the
room swiss number. It does not answer the bearer room swiss number itself. A
client taking a steward mints or recovers the room link it already has,
computes the same public identity, and retains the candidate only when the two
match. A failed candidate is released before the existing steward can change.

Claiming is an explicit product act because it adds durable server state. Room
details separate the capability from its operations: they show whether this tab
holds moderator authority, offer the claim or a place to take shared authority,
and expose the moderator sturdyref for copying once held. Possession reveals the
room-scoped moderation operations and nothing application-wide. `/moderator`
reaches the same claim and status path. `/moderator <sturdyref>` takes authority
somebody shared. `/kick` and the details action are two faces of the same live
steward reference.

## Scope (what this does not decide)

- A kick is an ordinary departure. There is no ban list, because the room has
  no durable member identity to ban.
- Sharing a sturdyref copies authority. ADR-0127 adds the separate server
  operator capability that can rotate it and invalidate every old holder.
- The IRC front does not map IRC operator modes onto the steward capability.
- Stewardship does not grant entry to the room. A holder needs a room
  capability separately.

## Alternatives Considered

- **Grant the first subscriber after every restart**: rejected because arrival
  order is not authority and lets a reconnect seize moderation.
- **Attach stewardship to a nickname**: rejected because names are temporary,
  reusable claims, not identities.
- **Return the room swiss number from `governs`**: rejected because validating
  moderation would also grant the distinct authority to enter and share the
  room.
- **Claim silently during every browser join**: rejected because an optional
  moderation claim would mutate durable state with no user act and would make
  operational failures look like ordinary lack of permission.

## Consequences

`RoomServerState` records bounded stewardship generations and whether each
generation has been issued. `RoomLinks` serializes persistence and publication,
restores current issued publications before listening, and derives separate
durable names for rooms and steward generations. The durable steward behavior
resolves the current room generation and verifies its own steward generation
when used, so it captures no state reclaimed on empty and no authority revoked after
enlivening.

Durable state accepts only its current schema. An old version, unknown
version, or malformed authority record fails at startup.

`RoomStewardship` owns the browser and library client's imported steward,
copyable links, exact-room validation, replacement, and release. The room UI
keeps the sturdyref as conversation state while `grants` reports only the live
reference held by the current membership.

## Evidence and gate

`apps/rooms/rust/services/src/server/tests/rooms.rs` covers issuance, typed
refusal, cross-room authority, replacement, kicking, return after a kick, and
restart restoration. `zig build rooms-web-page` covers the visible claim,
possession status, bearer warning, copyable capability, and the resulting
`/kick` grant. `zig build rooms-server-test` aggregates the Rooms server and UI
contracts. Rust server-document tests prove that state refuses old and unknown
schemas. ADR-0127 names the revocation evidence.
