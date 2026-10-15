---
id: ADR-0236
status: accepted
date: 2026-10-14
tags: [engine, outbound, memory, performance, v1_0]
decision: "The engine encodes a deliver when it admits it. The pending queue holds the frame, the listener frame next requires, and the exports, answer, and resolver recording took, so a borrowed tree is the caller's again when the send returns and nothing after admission walks it."
supersedes: []
superseded_by: []
amends: [ADR-0194]
amended_by: [ADR-0246]
---

# ADR-0236 A deliver leaves the queue as its frame

## Context

A far send of application values reached the wire through five walks of its
tree after the Host lowered it: the Vat cloned the tree into the engine's
queue, admission inventoried it (ADR-0234), the budget measured it, the drain
encoded it, and the drain freed it. The session acts on a message's
references, never its values, and the inventory already listed every
reference at admission. Everything after that point only needed the list.

The queue held the tree because three later owners read it. The drain encoded
it. Retraction of a failed turn (ADR-0194) released the retains recording took
by walking the tree again. On V1.0, the drain minted the resolver export an
answered deliver advertises as `resolve_me_desc` at emission, and on next the
same mint already happened at admission for the trailing `op:listen`. The two
profiles committed the same authority at different times for no reason the
protocol gives.

## Decision

Admission encodes a deliver, and on next any operation that produces an
answer, as the last fallible step before recording it. The queue row is
`engine.outbound.Encoded`: the frame, the listener frame next requires behind
it, the answer the send installed, the resolver export minted for it, and the
list of near exports recording retained, in wire order. The row's charge is
its wire bytes plus its list. `Session.listSentExports` produces the list
from the inventory, and `Session.retractSend` takes the list and the answer
instead of a tree. V1.0 mints its resolver at admission too, through the same
`mintMentionedResolverExport` seam next uses, so both profiles commit the
resolver with the send.

`Peer.sendBorrowed` is the borrowing entry: a deliver whose tree lists no
reference leaves as its frame with no copy, and the Vat calls it from the
caller's stack buffer. The kinds the queue keeps past admission are still
cloned there: a hello, a release, a listen, a resolution, and a deliver whose
tree lists a reference, handoff, or set, because the session rewrites those
slots in place and the Node may hold the tree while it stages a handoff.

A refusal at admission keeps nothing. The resolver, the frames, the list, and
the seat return in order, and the session is untouched because recording is
the last fallible step, so the same send retries. An oversized producer is
refused on the tree's retained bytes before the encoder allocates.

## Scope (what this does not decide)

- Whether a deliver that lists a reference can leave as its frame too. The
  shortening rewrite and Node staging read the tree, and this record keeps
  them on the cloned path.
- The inbound side. A received frame's parse and lift are ADR-0231's.
- The hello and the gc export closure, which the drain still reads at
  emission.

## Alternatives Considered

- **Keep the tree and drop only the Vat's clone.** Rejected: the drain's
  encode and free walks and the budget's measure walk stay, and retraction
  still walks the tree.
- **Encode at emission from a borrowed tree the Vat keeps alive.** Rejected:
  the Vat's turn arena is reset before the next drive, so the queue would
  borrow freed storage, and the embedder's step order would become a
  lifetime rule.
- **Mint the V1.0 resolver at emission as before.** Rejected: an answered
  deliver could not be encoded at admission without its `resolve_me_desc`,
  and the guard against a released answer is already the resolver tombstone
  `releaseOutbound` installs, so emission-time minting protected nothing.

## Consequences

- `src/ocapn/engine/outbound/encoded.zig` owns the row and its admission.
  `outbound/drain.zig` moves the frames to `outbound` and keeps no tree arm
  for a deliver.
- `peer/provisional.zig` retracts from the row's list, answer, and resolver.
- `engine.v1_0` no longer prepares an outbound deliver. Its projection
  listener preparation stays at emission.
- A common-arity far send allocates its frame and nothing else, which
  `test/actors/vat_alloc_budget_test.zig` pins.
  `test/engine/peer/encoded_send_test.zig` pins the retraction and the
  refusal.
- The memory ledger's outbound boundary copy entry names the kinds that
  still clone.
