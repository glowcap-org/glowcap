---
id: ADR-0074
status: accepted
date: 2026-07-11
tags: [session, engine, actors, driver, c-abi, security, gc]
decision: "Partner admission of a near export requires a wire-count grant: an export row's refcount is its local baseline plus the wire references and explicit grants on top, a partner may address only a position whose wire-held share (`ExportTable.wireHeld`, count minus baseline) is nonzero, and a reserved-but-ungranted position is refused with the same `InvalidReference` as a nonexistent one. `Session.allocateExport` / `reserveExport` are the reservation (baseline only). The capability's first marshal is the grant (`retainSentExports`, which also mints absent rows registerExport-shaped and advances the allocator past them). `Session.registerExport` / `Peer.exportObject` / `glowcap_peer_register_export` are the explicit out-of-band grant. `Port.bindExport` reserves and never grants. Inbound `op:gc-exports` validates its cumulative deltas against `wireHeld`, never raw `count`, so a partner over-release is a loud `GcUnderflow` and an export row can never be deleted by the partner."
supersedes: []
superseded_by: []
---

# ADR-0074 Grant-on-marshal export admission

## Context

If a spawned capability's export position is addressable the moment it is
allocated, a partner that guesses the small, dense integer can
deliver to it between the spawn and the first send of its reference. This
covers `driver.spawnAt` (and every surface riding it: `Served.spawn`,
`glowcap_host_session_spawn`, `glowcap_host_turn_spawn`, the bindings' `spawn`)
and published-but-unfetched bootstrap capabilities (`registerBootstrapCap`).
Positions are not swiss numbers and carry no entropy, so "the partner has not
been told the number yet" is no boundary. A reference is authority, an integer
a partner never received must not be, and every inbound frame is untrusted
until session validation says otherwise.

A second hazard sits in the same table. Every export row carries a local
baseline of one (`allocateExport` / `registerExport` seed the row at count 1,
and `count == 1 + wire references` is pinned by `test/session/gc_test.zig`).
If inbound `op:gc-exports` validates its deltas against the raw `count`, and
`SlotTable.decrement` removes a row at zero, an untrusted peer releasing one
more than it was sent drives the count to zero and deletes the row, after which
our own next marshal of that capability fails `validateSend`. One frame from a
partner would kill our live capability.

## Decision

Admission lives in the session's tables, where authority lives. An export row's
refcount is one local baseline plus everything the partner was granted: each
wire mention (`retainSentExports`, on every send path) and each explicit grant
(`registerExport`). `ExportTable.wireHeld` (`src/ocapn/session/export_table.zig`)
names the partner-releasable, partner-addressable share: count minus baseline.
The one reference validator (`validateReference`,
`src/ocapn/session/validate.zig`) takes a comptime perspective: on the `sent`
side a near mention needs only a live row, so a reservation can marshal. On the
`received` side the partner may name an export only when `wireHeld` is nonzero
(the pinned bootstrap position excepted). A reserved-but-ungranted position is
refused with the same `InvalidReference` a nonexistent one raises, so a probing
partner cannot learn that a reservation exists.

The verbs split along the same line. `allocateExport` and the positional
`reserveExport` are the reservation. `spawnAt` and `registerBootstrapCap`
route through them, so spawned and published-but-unfetched capabilities are
unaddressable until their reference first crosses the wire: the fetch reply
or the spawning turn's own reply is the grant, and it lands under the ordered
stream before the partner can act on it. `registerExport` (and `Peer.
exportObject`, `glowcap_peer_register_export`) is the explicit grant for
positions a partner legitimately learns out-of-band. `Port.bindExport`
(`src/actors/vat/mod.zig`) reserves and never grants: binding an actor to a
position is routing, not authority. Minting is uniform: a first-export marshal of
an absent row (`retainSentExportRef`, `src/ocapn/session/apply.zig`) installs
the baseline plus the mention and advances the export allocator past the
position, so every row obeys the one counting contract and `allocateExport`
can never re-issue a marshal-minted integer.

The GC floor rides the same arithmetic: `checkGcExportDecrement`
(`src/ocapn/session/gc.zig`) validates an inbound `op:gc-exports`' cumulative
deltas against `wireHeld`, never raw `count`, so a partner over-release is a
loud `GcUnderflow` and inbound GC can never delete an export row. Releasing
every wire reference returns the row to its reserved state: alive at baseline,
unaddressable until re-granted.

## Scope (what this does not decide)

Import-side accounting is unchanged: an import carries no local baseline, so
its `wireHeld` is its count. The V1.0 resolver-callback seam is unchanged: a
deliver to a known resolver export routes through the resolver link, which
survives a released wire mention and can only settle the answer the
resolver was minted for. Positions stay small dense integers. This ADR does
not add entropy to them, it removes the need for it at this layer.

## Alternatives Considered

- **Lazy position minting at the marshal chokepoint** (no position exists until
  the reference first encodes). Rejected: the C ABI's identity model is the
  eager position. `glowcap_host_session_spawn` and its kin return the export
  position at spawn time, so lazy minting forks near identity into a
  token-plus-position pair across five bindings, while the session-table rule
  closes the window for every producer, including a raw engine consumer that
  never touches the driver.
- **Swiss-number-sized random export positions**. Rejected: positions are a
  wire-visible dense keyspace the tables and benches are built around, and
  entropy would hide the admission gap instead of closing it.

## Consequences

A partner probing a reserved position gets the same `InvalidReference` abort
as a nonexistent one. Nothing distinguishes the two from outside. Hand-wired
consumers that share positions out-of-band (paired-peer tests, examples that
wire both ends by hand) use an explicit `exportObject` / `register_export`
grant. `ExportTable.retain` asserts the row exists, so a baseline-less
count cannot be minted by accident. Pinned by the admission and GC-floor
scenarios in `test/session/grant_test.zig` and the end-to-end
spawned-capability probe in `test/driver/session_loopback_test.zig`. The external
arbiters are the live Goblins interop and the upstream OCapN suite, which
exercise fetch, GC, and withdraw against these rules.

## Notes

Builds on ADR-0008 (wire-delta GC accounting) and ADR-0010 (perspective
flip). The explicit-grant verb is `glowcap_peer_register_export`.
