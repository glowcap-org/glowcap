---
id: ADR-0135
status: accepted
date: 2026-08-25
tags: [rooms, persistence, capabilities, schemas, architecture]
decision: "Rooms keeps intent, live capability custody, durable resource records and presentation at their owning boundaries. Session codecs and exact saved fields compose atomically through Loam."
supersedes: []
superseded_by: []
amends: [ADR-0129, ADR-0133, ADR-0134]
amended_by: [ADR-0136, ADR-0137, ADR-0138, ADR-0139, ADR-0141, ADR-0142]
---

# ADR-0135 Rooms state authority graph

## Context

Directory discovery, room membership, archives, session intent and browser
presentation have different owners. Nesting their descriptions in a workspace
cannot give the workspace authority over them or make their lifetimes equal.

## Decision

Treat Rooms state as an authority graph. Plain identifiers and bounded view data
describe resources. Held capabilities and explicitly acquired saved fields carry
authority. A bearer link is secret acquisition material. Workspace intent
stores typed custody coordinates rather than recreating authority from a label.

| Domain | Durable owner | Live owner |
| --- | --- | --- |
| Directory and room service | Server authority and operations documents, room identity and policy generations. | Registrations, memberships, invitations, signaling, line actors and upload custody. |
| Session | Loam workspace, custody pages, receipts, grants and independent use/control publications. | Supervised workers, exact sources and targets, inbox callbacks and observations. |
| Member archive | Bounded records, source/generation identity and retained blobs on its selected backend. | Admitted capture queue, scoped readers and pending storage operations. |
| Bridge secrets | Private credential document with bounded scope and retained recovery witnesses. | Credential staging and secret-bearing dispatch through the original source. |
| Browser page | Explicit display preferences and its separately owned archive. | Non-authoritative projection, modal state, object URLs and pending reader gestures. |

Rust application declarations own session schemas, permission requirements and
operation routing. Generated browser metadata mirrors those declarations. JSON
view decoding supplies structure. Shared Loam owns grant semantics, ancestry and
exact saved capability identity. The [session guide](../../rooms/session.md)
owns atomic graph preparation, bootstrap and consumer contracts.

Source loss invalidates protected cached activity. Reconnect uses the
saved source and targets. A nickname or URI-shaped view field cannot select a
replacement grant. Runtime lifetime markers retire old live registrations and
routes across restart while preserving intended navigation, drafts and receipts.

Archive records and blobs stay in the selected archive. Disabling recording
commits pending erasure and bars re-enablement until that erasure settles.
Shared records and other owners remain intact. Secret-bearing forms save private
custody before committing dependent intent and reveal no secret in a snapshot
or export.

## Evidence and costs

The [session graph trace](../../../apps/rooms/rust/proofs/src/session_storage/mod.rs)
checks atomic state and receipt replacement, refusal and physical reopen.
The [foreign-field trace](../../../apps/rooms/rust/proofs/src/session_foreign/mod.rs)
checks exact saved custody through cold restoration and browser reload.
Budgets cover encoded pages, field populations, retained calls and projection.
Each owner refuses malformed state rather than interpreting it as empty or
privileged state. State reset is an explicit operator action.
