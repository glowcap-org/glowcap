---
id: ADR-0043
status: accepted
date: 2026-10-19
tags: ["rooms", "capabilities", "sturdyrefs", "moderation", "persistence", "revocation", "handoff", "locators"]
decision: "A room has stable identity independent of registration."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0043 Rooms identity and authority

## Context

A nickname, public room registration and reconnect order are not durable authority. Room operation, membership, entry and moderation need independently held capabilities.

## Decision

A room has stable identity independent of registration. Reusable or one-shot entrances mint live memberships. The directory publishes only the entrance selected by the room manager.

A durable steward is explicitly granted and taken after validation against a non-authority room identity. A separately minted operator capability can inventory, give and revoke server-owned stewardship. Revocation rotates the durable generation and live behavior checks it on every call.

Rooms are addressable units that directories can pass through ordinary handoff. Directory-local nicknames remain local claims. IRC adapters operate at the application edge rather than importing IRC server federation into CapTP.

A client learns authority by the facets it receives, and learns descriptive facts from explicit state. It does not probe verbs to infer permissions. Courtesy features do not acquire invented capabilities merely to make every feature look alike.

## Alternatives and consequences

Granting the first subscriber after restart permits authority capture by arrival order. Tying stewardship to a nickname permits reassignment. Giving an operator the room's ordinary moderation behavior would collapse distinct grants. IRC server federation would add ambient cross-server trust.

Policy changes need not rotate unrelated room authority. An invitation's bearer conveys its declared entry right, not management of the room or directory.

## Evidence

Rooms authority, generation, membership and directory tests exercise these distinctions. [The Rooms guide](../../../apps/rooms/README.md) owns user-facing operation, and [stability](../../stability.md) records live interoperability coverage.
