---
id: ADR-0127
status: accepted
date: 2026-08-25
tags: [rooms, capabilities, moderation, revocation, persistence]
decision: "A separately minted Rooms operator capability inventories, gives, and revokes every server-owned room stewardship. Revocation rotates its durable generation and every old behavior checks that generation on each call."
supersedes: []
superseded_by: []
amends: [ADR-0126]
amended_by: [ADR-0133]
---

# ADR-0127 Room moderator authority under the Rooms operator

## Context

ADR-0126 makes moderation an explicit, durable room capability and supplies no
recovery or revocation mechanism. A holder can share the steward sturdyref, yet an operator can neither restore
stewardship to a room whose holder lost it nor stop a copied capability from governing. Removing a swiss from the
current publication table is incomplete: a holder may already have enlivened the reference.

The Rooms server mints application-wide capabilities at boot for diagnostics, listeners, IRC, peering, and
visualization. Stewardship operation has the same authority boundary. It is not a public directory method, a room
membership rank, or moderation itself.

## Decision

`--operator` (or `GLOWCAP_ROOMS_OPERATOR=1`) publishes a sibling boot capability under the persistent `ROOMS-OPERATOR`
swiss. Holding it permits three operations:

- `list()` inventories stewardship for every local room this server owns
- `giveSteward(name)` issues an unissued steward or recovers the current one
- `revokeSteward(name)` rotates an issued steward and leaves it available for a later, explicit grant

The operator cannot kick a member. It manages room-scoped steward capabilities. The steward remains the only object that
performs room moderation. Foreign peered rooms and IRC bridges are absent because their source owns their moderation.
Private local rooms are included, using their opaque durable key. The human label is shown only while the live room
still knows it.

Each stewardship record carries a non-negative generation and whether that generation is issued. Generation zero derives
the durable name used by ADR-0126. Revocation persists the next generation as unissued before answering, and later
issuance derives a different swiss. Every durable steward behavior consults the current record before every verb,
including `governs`. A revocation therefore disables both later redemption of copied sturdyrefs and references already
enlivened on live sessions.

The browser treats `operator` like the other operations capabilities: it is taken from Settings, remembered only on an
explicit browser ask, and receives its own `/ops/operator` pane. The pane lists all rows and copies the complete
sturdyrefs the Host authors for that session. It requires a second, plainly worded confirmation before revoking every
old holder.

## Compatibility and state

Rooms state version 3 records `{name, generation, issued}` per stewardship and is the
only accepted schema. Old, unknown, and malformed state is a startup failure.

## Alternatives considered

- **Make operation a directory method:** rejected because every member can fetch the directory, while stewardship
  recovery and revocation are deployment-wide authority.
- **Let the operator perform `kick`:** rejected because it collapses authority management into room moderation and makes
  the room-scoped capability ceremonial.
- **Delete the current swiss on revoke:** rejected because an already-live reference no longer consults the publication
  index.
- **Tie stewardship to an account, nickname, or room rank:** rejected because Rooms grants capability references, and
  nicknames are temporary claims, not durable identities.
- **Exclude private rooms:** rejected because the operator is the server-wide recovery root. Their opaque
  durable names avoid turning a private label into an address after the room becomes empty.

## Consequences and evidence

The operator capability is powerful bearer authority and is off unless minted. Deployments may withhold it
independently of every other server capability. Losing its swiss does not affect room operation, while disclosing it
grants recovery and revocation over every server-owned room.

`apps/rooms/rust/services/src/server/tests/operations/operator.rs` proves recovery is idempotent and revocation stops a separately enlivened
reference with typed `not-steward`. The room-server restart scenarios prove only the replacement survives restart.
`server_links_test.ts` proves exact prerelease schema admission.
`zig build rooms-web-page` drives the visible take, give, copy, confirmation, revoke, and drop flow through the browser
peer.
