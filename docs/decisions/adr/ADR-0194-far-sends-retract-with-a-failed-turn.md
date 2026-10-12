---
id: ADR-0194
status: accepted
date: 2026-10-04
tags: [actors, vat, turns, engine, node, goblins, semantics]
decision: "A failed outermost turn retracts the far sends it made. The Vat owns the turn outcome and tells each enrolled participant to commit or abort once: the Peer retracts sends recorded in its provisional window, the Host rolls back the capability lowerings those sends used, and the Node withdraws staged outbound and handoff deposits."
supersedes: []
superseded_by: []
amends: [ADR-0191]
amended_by: [ADR-0201]
---

# ADR-0194 Far sends retract with a failed turn

## Context

ADR-0191 holds a turn's local sends until the outermost turn returns. Far
sends still reach the Peer when made, so a turn that throws after a far send
emits it, which Goblins does not (`core.rkt` discards the turn's messages,
remote ones included).

A far send from a turn touches four owners, which is why it cannot simply be
held:

- **Session:** `recordSend` takes a wire-delta retain on every `near` export
  the message names and installs the outbound answer row. On `next`, an
  answered operation also mints a paired resolver export and its `op:listen`.
- **Peer:** the pending queue holds the semantic message and its admission
  charge. Nothing is encoded while the Vat executes, because the Host defers
  `step` until the turn returns.
- **Host:** `capabilities/lower.zig` projects application values onto the
  session and commits its rollback receipts when `Peer.send` returns. The
  lowering leases it lends the Node last only for that call.
- **Node:** when routes exist, a message carrying a capability from another
  session may wait in entropy staging, and its handoff deposits a gift on the
  exporter's session.

Holding the message in the Vat and sending it at commit was tried. It failed
because the handler may release an import the held message names, and because
the leases and receipts were gone by commit time.

## Decision

1. **The Vat owns the outcome.** A layer that records a turn effect enrolls
   once per outermost turn (`Vat.enrollTurn`) and later receives exactly one
   call: `commit` inside the frame before the reply, in enrollment order, or
   `abort(reason)` after the frame closes, in reverse.
2. **The Peer keeps a provisional window.** A Port enrolls at its first far
   send of the turn and opens its Peer's window. While it is open, each
   deliver the Peer queues is marked provisional on its pending row. Abort
   removes each marked row, which keeps every other row in order, because
   releases and listens share the queue:
   - it frees the row's message and returns its charge
   - it releases the row's export retains with `sent_exports.releaseMessage`,
     the exact inverse of `retainMessage`
   - it retires the outbound answer row and, on `next`, abandons the paired
     resolver export first, because that link names the answer
   - the Port breaks the retracted send's vow with the turn's error, or, with
     no listener yet, records it so a later `on` is refused
   Commit clears the marks. A row a step encoded before the outcome has left
   the Peer and stays sent. Only an embedder that steps inside a handler can
   reach this case.
3. **The Host defers its receipts.** A Host send made inside a turn calls
   `holdForTurn` before the send, which enrolls the Host and reserves room, so
   its lowering receipts move to a turn list when it commits. Commit forgets
   them. Abort runs after the Port has retracted the sends, and rolls back each
   minted projection that no surviving message names (its export count is back
   at its baseline), the rule `finishLocalBorrow` already applies.
4. **The Node withdraws its staging.** A send whose arguments name a
   capability from another session waits in Node staging for gift ids, behind
   a row it reserved in the recipient's queue (ADR-0201). The window marks that
   row like any other. Retraction removes it and tells the Node
   (`NodeServices.stagedWithdrawn`), which fails the batch: its gift tickets
   and leases are cancelled and its answer breaks. No gift has been deposited
   by then, because the embedder does not pump while the turn runs.

   A send that projects only promises has no gift id to wait for, so its batch
   finishes while it stages and commits the promise proxy at once: the home
   session's queued `op:listen`, its listener export and resolver, and the
   recipient's promise export and third-party import. The Node keeps a receipt
   for each recipient a send inside the window commits. When the Peer closes
   the window (`NodeServices.provisionalClosed`), after it has retracted its
   own rows, commit keeps them, and retraction withdraws them newest first. A
   proxy the window created leaves with its last recipient, including its
   queued listen. A proxy that existed before the turn keeps its home and
   loses only the window's recipients.
5. **Releases stand.** `op:gc-exports` and `op:gc-answers` a handler issues
   are not retracted. Retraction only removes items, so the release that
   followed a retracted send remains valid on the wire.

## Scope (what this does not decide)

The inverse walk in step 2 depends on the forward walk being
atomic. It is: validation requires a live export row for every sent `near`, so
`sent_exports.retainMessage` only increments rows, and a refused send takes no
retain.

## Alternatives Considered

- **Hold far sends in the Vat.** Rejected for the reasons in Context.
- **A table-level undo log.** Rejected: every send would pay a log entry per
  mutation, inside or outside a turn, while only turn sends can be undone.
- **Snapshot session state at turn start.** Rejected: the cost is the size of
  the session, not the size of the turn.

## Consequences

- A send outside a turn pays nothing. A far send inside a turn pays one flag
  on its pending row and one enrollment per Port per turn. The Peer gains one
  flag within its struct budget. The Host's Vat gains the participant list.
- Host lowering gains a turn-scoped receipt list, and the Node a list of the
  batches staged for an open window. Each is one list per Host.

## Evidence and gate

[`test/actors/vat/turn_far_test.zig`](../../../test/actors/vat/turn_far_test.zig)
serves a deliver whose handler sends far, with and without an answer, on both
profiles: a failed turn sends its caller only the break, breaks the retracted
send's vow, and leaves the session's export and answer tables as they were. A
successful one sends both. The atomic forward walk is held by
[`test/session/gc_test.zig`](../../../test/session/gc_test.zig) ("a send refused
for memory takes no export retain").
[`test/driver/core_host/turn_lowering_test.zig`](../../../test/driver/core_host/turn_lowering_test.zig)
shows a failed turn's Host send leaves no projection and no queued send, and a
successful one keeps both.
[`test/driver/core_host/turn_staging_test.zig`](../../../test/driver/core_host/turn_staging_test.zig)
shows a failed turn's send carrying another session's capability is withdrawn
from Node staging and never reaches its recipient. On both profiles, a failed
turn's send carrying only another session's promise leaves no proxy, no queued
home listen, and no new export or import row. A successful one keeps its home
listener.
