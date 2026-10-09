---
id: ADR-0203
status: accepted
date: 2026-10-05
tags: [loam, hosting, lifetime, rooms]
decision: "A live hosting lifetime uses its own transactionally advanced marker; the Store opening incarnation only fences writers."
supersedes: []
superseded_by: []
amends: [ADR-0182]
amended_by: [ADR-0204]
---

# ADR-0203 Live lifetimes use independent restart markers

## Context

Rooms seats, line handles and upload state end with their hosting lifetime.
Saving durable workspace intent cannot preserve those runtime capabilities.
The [storage contract](../../planning/rooms/persistence.md) requires a marker
advanced before admissions open after restart, with bounded later retirement.
It also requires exact held authority, explicit ownership and atomic staging.

`Store.metadata.incarnation` advances at exclusive backend opening. A Host can
restart while that Store remains open. Reusing the writer fence would leave
the old live lifetime valid in that case. Scanning every stored grant or result
at startup would make restart cost depend on unrelated authority populations.

## Decision

[`hosting::LiveEpoch`](../../../src/loam/hosting/live_epoch.zig) owns a rooted
record containing a nonzero generation and the opening transaction identity.
The embedding retains its object name
as trusted startup metadata. The name and generation describe a lifetime;
they cannot restore or manufacture a capability.

The hosting owner stages a generation advance in the existing Store transaction
before opening live admissions. Expected record revision and refusal of a
second advance in the same transaction prevent competing restart proposals
from sharing the same next generation. Overflow refuses without staging.

The proposal cannot activate a lifetime before confirmed installation. After
commit or exact recovery, confirmation uses a new current lease over that exact
row, generation and opening attempt. An aborted proposal cannot accept another
attempt's committed generation. Unknown outcomes admit neither lifetime until recovery.
An aborted advance leaves the previous committed marker intact. Every live
restoration must compare its saved marker with current hosting state.

## Scope

The shared epoch codec and transaction helpers are implemented.
[ADR-0204](ADR-0204-live-recipes-retain-exact-runtime-custody.md) owns live
reference custody and hosted C/Rust activation. The
[session guide](../../rooms/session.md) describes production Rooms startup.
Ordinary durable save requests continue to refuse live-only capabilities.

Epoch advancement performs no population scan. Exact live custody and its
bounded retirement belong to the hosting scope; the marker supplies no
capability or permission policy.

## Alternatives considered

- The Store incarnation misses a Host restart within one opening.
- Serializing Host capability handles cannot preserve actual authority across
  runtime teardown and handle reuse.
- Eagerly rewriting old live rows makes restart depend on population size.

## Evidence

[`live_epoch_test.zig`](../../../test/loam/hosting/live_epoch_test.zig) exercises
restart within one Store opening, duplicate advance refusal, stale snapshots,
abort and retry, both unknown-write resolutions, backend close/open, invalid
markers and exhaustion. These shared Zig scenarios establish the marker
contract. They do not establish live reference restoration or production startup.
