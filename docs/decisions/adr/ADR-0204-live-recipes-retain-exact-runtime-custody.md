---
id: ADR-0204
status: accepted
date: 2026-10-05
tags: [loam, hosting, lifetime, capabilities]
decision: "Live fields use graph-owned recipes and a bounded shared hosting scope that retains the exact capability until collection or lifetime close."
supersedes: []
superseded_by: []
amends: [ADR-0182, ADR-0203]
amended_by: [ADR-0205]
---

# ADR-0204 Live recipes retain exact runtime custody

## Decision

An explicit `save_live` declaration saves authority for the current hosting
lifetime. Ordinary durable saves retain their existing refusal contract.
The shared Zig `LiveScope` owns a bounded reservation table and an index keyed
by the actual recipe record identity. Each reservation retains the exact Host
capability before preparation can wait. No Host handle, slot index or actor
reconstruction instruction enters storage.

A live recipe stores its opening epoch and one strong edge to the epoch row.
Stored field occurrences retain the recipe through the portable graph. Scope
entries do not root their recipes. Warm restoration requires a current checked
epoch, that exact recipe identity and its actual runtime retain. A new scope
has no old actual capabilities and refuses old recipes with `LiveReferenceExpired`.

Recipe creation and application fields share one Store transaction. Unknown
writes keep reservations through exact recovery. Known commit transfers custody
into the runtime index before outward reply projection. Known absence or
preparation retirement cancels uncommitted reservations. This confirmation
belongs to the reference Set and composes with the continuation's independent
confirmation slot. Reply refusal cannot erase already committed live custody.

Startup stages its own epoch advance and confirms its exact opening attempt
before admitting live fields. The optional hosted startup path uses the
attachment's existing storage work and recovery lane. C and Rust project this
path and register the epoch schema with their shared schema inventory.
Trusted persisted marker names describe startup state and carry no capability.

After a committed revision, maintenance visits one runtime inventory slot per
step. It loads recipes through the existing read lane, consumes its expected
missing-record completion and releases the retain when collection removes the
recipe. Scope close releases its bounded runtime inventory after reservations
and submitted work retire. Startup and cleanup inspect no grant population.

## Consequences

Live fields consume independently configured runtime capacity. They preserve
exact authority during one lifetime and cannot make seats, uploads or line
handles survive restart. Saving a live capability also does not implement
source or upstream permission checks; mediated readers still require those
checks on each operation.

Shared hosting tests establish reservation pressure, commit and absent recovery,
canceled observation, reply refusal, bounded collection retirement and restart
within one Store opening. Backend consumer tests own LMDB/IndexedDB projection
and reload evidence. Production Rooms uses these lifetimes through the
[managed session](../../rooms/session.md).
