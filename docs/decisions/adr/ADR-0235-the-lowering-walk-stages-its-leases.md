---
id: ADR-0235
status: accepted
date: 2026-10-14
tags: [host, handoff, performance]
decision: "The Host walk that lowers application values onto a session also stages the retains an inline-Passable batch may claim, one per routed reference it lowers, so a far send walks its values once. A near or far reference takes no retain."
supersedes: []
superseded_by: []
amends: [ADR-0116]
amended_by: []
---

# ADR-0235 The lowering walk stages its leases

## Context

A far send of application values walked them four times on the Host before
`Peer.send` saw them: one walk counted the capabilities, one retained each
capability (ADR-0116), one lowered the values onto the session, and one bound
each lowered reference to its retain as a staging lease for the Node. The
retain and the lease were parallel records, paired by walk order, and every
capability took one, though the Node's `claim` matches a lease by route id and
only a routed reference carries one. A near export or a far import never
staged a gift, so its retain was taken and released for nothing. On the
`report` row of `bench/iroh_bench.zig`, which carries no capability, the
three extra walks still descended every node, about five thousand of the
caller's sixty-nine thousand instructions per round trip.

## Decision

`PreparedValues` in `src/driver/core/host/capabilities/lower.zig` is the one
staging transaction. The walk that lowers a value stages a lease when, and
only when, a capability lowers to a routed reference: it takes one more Host
retain on the capability and appends `{route id, retain}` to the transaction's
lease list, in lowering order. `beginStaging` lends that list to the Node for
one synchronous send, and `endStaging` closes the window. A lease the Node
claimed belongs to the staged Passable, which releases it through the Node's
`release_capability` action. Every unclaimed lease is released when the
transaction ends, on commit, local borrow, or rollback alike. A failed
lowering rolls back its projections and returns its lease retains in the same
step.

`retainValueCapabilities` remains for the owners that keep values past the
call: a queued local message, a deferred send waiting on its promise, and a
Loam call. Those retains are custody, never leases, so they are plain
capability handles and carry no transfer flag.

## Consequences

- A far send prepares its values in one walk. A message with no capability
  touches no retain, no lease, and no allocation beyond its lowered spine.
- A direct lowering with no send (`lowerValue`, a reply) retains and releases
  a routed reference inside one call, which is the price of one rule for every
  lowering. Routed references are rare and the cost is a table lookup.
- The staging window is open on exactly the sends that lowered their values
  through `PreparedValues`: application sends and tells, deferred sends, the
  wire answer of a resolver, and a proxy listener's relay. A send that passes
  lowered arguments directly still stages without leases, as before.
- `test/driver/core_host/capability_projection_test.zig` pins that a failed
  lowering returns the retain it staged on a routed reference and that a
  near reference takes none. The turn staging and lowering tests hold the
  claimed path.
