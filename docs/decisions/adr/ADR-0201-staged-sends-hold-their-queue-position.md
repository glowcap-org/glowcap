---
id: ADR-0201
status: accepted
date: 2026-10-04
tags: [engine, node, ordering, handoff, turns]
decision: "A send the Node stages for gift ids reserves a row in the recipient Peer's pending queue at the moment it is sent. A step stops at that row, the finished batch fills it in place, and a failed batch removes it."
supersedes: []
superseded_by: []
amends: [ADR-0194]
amended_by: []
---

# ADR-0201 Staged sends hold their queue position

## Context

CapTP delivers the messages one session sends in the order it sent them. A
send whose arguments carry a capability from another session cannot be encoded
until the Node has minted a gift for each such capability, which waits for gift
id entropy from the embedder. While it waited, the Node kept the carrier in its
own staging (`src/ocapn/engine/node/passable/batches.zig`) and appended it to
the recipient Peer with `Peer.send` when the batch finished. The recipient's
queue had no record of the send in the meantime, so a later send to the same
recipient was encoded first. One turn that sent `gift` and then `plain` to one
sink delivered `plain` first. The only reservation staging held was a byte
budget (`reserveInlinePassableStaging`), not a position.

Ordering is a CapTP guarantee, and an application cannot repair it above the
library.

## Decision

The position is reserved where the order is decided. `batches.stage` reserves
one row in the recipient's pending queue (`Peer.reserveStagedRow`) before its
last fallible step and publishes it as an `Outbound.staged` row naming the
batch. The row costs a queue seat and no bytes. The carrier's bytes stay
charged to its staging reservation.

- `Peer.step` stops before a staged row at the head while the session is open,
  so every later carrier waits behind it. A closed session discards rows as
  before, so it never waits.
- When the batch finishes, its carrier is sent as before and the appended row
  moves into the reserved one (`Peer.fillStagedRow`), keeping the reserved
  row's provisional mark.
- When the batch fails, `Peer.removeStagedRow` removes the row and reports
  whether a sendable carrier now heads the queue. Only then does the Node
  queue a flush for the recipient. A retiring recipient removes the rows of
  its batches as they retire.

The provisional window of ADR-0194 covers staged sends through the same rows: a
staged row made inside the window is marked, retraction removes it like any
other marked row, and the Peer tells the Node to fail that batch
(`NodeServices.stagedWithdrawn`). The Node keeps no list of its own for batches
staged in a window.

## Scope (what this does not decide)

- A relayed promise settlement that the Node stages for a proxy recipient
  (`Destination.relayed`) reserves no row. Its order relative to the
  recipient's other traffic is not decided here.
- Session-state recording still happens when the carrier is sent, so a later
  carrier records before an earlier staged one. Only wire order is decided.

## Alternatives Considered

- **A per-recipient barrier in the Node.** Later sends would join Node staging
  while any batch for that recipient is pending. Rejected: answer releases,
  listener fires and session-owned releases never pass through the Node, so
  they would still overtake the staged send.
- **Hold the staged send until the turn ends.** Rejected in ADR-0194: the
  carrier would follow the turn's later sends, and promise admission assumes
  its commit follows preparation at once.

## Consequences

- `Outbound` gains the `staged` arm, and the pending-charge and encode switches
  name it.
- One staged gift send delays every later carrier to the same recipient until
  its gift ids arrive. Before this change, only the staged send itself waited.
- ADR-0194's Node rollback step runs through staged rows. Its window-end hook
  (`NodeServices.provisionalClosed`) remains for proxy recipients a promise-only
  send commits during staging.

## Evidence and gate

- [`test/driver/core_host/gift_order_test.zig`](../../../test/driver/core_host/gift_order_test.zig):
  on both profiles, a turn that sends `gift` then `plain` delivers `gp`, and a
  failed turn delivers neither.
- [`test/engine/node/staged_order_test.zig`](../../../test/engine/node/staged_order_test.zig):
  on both profiles, a carrier behind a staged gift waits, the gift's entropy
  failure flushes and sends it alone, and a closing recipient discards the
  staged row.
- `zig build test`.
