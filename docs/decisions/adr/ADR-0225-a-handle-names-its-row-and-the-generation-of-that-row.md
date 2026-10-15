---
id: ADR-0225
status: accepted
date: 2026-10-14
tags: [engine, driver, actors, performance]
decision: "A handle this process mints names its row's index in the low half of one word and the generation of that row in the high half. The table that mints it owns the index space and frees a row for reuse under the next generation, and a table in another layer keeps its own row under the same handle. A lookup is a bounds check and one compare, and a stale handle fails closed."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0225 A handle names its row and the generation of that row

## Context

The node's peer table, the host's session table, the runtime's wire table,
and the Vat's ingress table were hash maps keyed by a handle this process
minted in sequence. The node drew peer handles from a monotonic counter and
never reused one, so a redeemed route that kept naming a dead exporter
session failed closed on a missing row. A dense array could not reclaim a
row without reusing its handle. Every lookup on the call path paid an
identity hash and a probe for a key that could have been an index: about
eight such lookups per round trip, each about a hundred instructions.

## Decision

`foundation.handle_table` owns the shape. A handle is a non-exhaustive
`enum(u64)` whose low half is a row index and whose high half is that
row's generation. An `Owner` mints handles and frees rows onto a free
chain, advancing the row's generation on every free, so the same index
under an older generation misses. A `Mirror` in another layer reserves and
places its own value under a handle an owner minted, and shares the index
space without minting. The node's `peers`, the host's `sessions`, the
runtime's `wires`, and the Vat's `ingresses` use it. `engine.PeerHandle`
and `actors.IngressId` carry the layout, and the zero handle, whose
generation is zero, names no row anywhere.

## Scope (what this does not decide)

A table whose keys a peer chooses stays a keyed hash under a per-session
secret (ADR-0218). A table whose keys an embedder-supplied issuer chooses,
such as the capability registry under a custom id issuer, stays a hash map.
A row freed 2^32 times answers to its first handle again: at one free per
microsecond that is over an hour of churn on one row, and the free chain
hands back the most recently freed row first, so churn spreads over few
rows. No generation is widened for it.

## Alternatives Considered

- **Keep the monotonic counter and the hash map**: rejected because the
  lookup cost is the hash and probe, not the counter.
- **Hold a row's address instead of its handle**: rejected because a
  pointer cannot fail closed, and the handle crosses the C ABI as a word.
- **One table shared by every layer**: rejected because each layer owns
  its own row's lifetime, and a session's wire is not the node's peer.

## Consequences

`Node.next_peer_handle` and `Vat.next_ingress` are gone. A host reserves a
session's row after the node mints its handle and places it in `enroll`.
The node's footprint pin moves by the table header. The gifter fixtures in
`test/engine/cross_peer` take the handle the node minted instead of
assuming the first handle is zero.

## Evidence and gate

`test/foundation/handle_table_test.zig` holds the mint, reuse, stale,
free-chain, and mirror contracts. `test/engine/node/tables_test.zig` holds
that a removed peer's handle finds nothing after a later peer takes its
row, and that a spent index space refuses registration before acquiring
resources. The tcp round-trip profile on the benchmarks page records the
saving.

## Notes

ADR-0218 keys the wire-chosen tables. ADR-0223 and ADR-0224 are the other
table seams on the same path.
