---
type: static
description: How to observe managed access by registering a receiver, keeping it alive, and canceling it.
audience: human
sources:
  - resource: /src/loam/access/hosting/
  - resource: /src/loam/access/storage/
---

# Observing managed access

Whoever holds a managed use or control endpoint can learn when its access
changes, for example when it is paused or revoked. The holder registers a
receiver, reads the changes through it with a cursor that marks where it last
read, and cancels the receiver when done. The
[managed access guide](access.md) covers use, control, and how edits are
checked.

## Registering a receiver

Call `mutate(sequence, "observe")` on a managed use or control endpoint to
watch its grant. The result holds two items: a receiver and a separate
canceler.

- Registering shares the endpoint's eight mutation receipts
  ([retrying mutations](access.md#retrying-mutations)). Resending the request
  returns the same receiver and canceler instead of creating another.
- Set `Service.entropy.fill` before registering.
- Facets made at run time, such as dependent facets, do not accept this
  method.
- A paused use can still read `mutation-sequence()`, register a new receiver,
  and read `durable-name()`, so reopening a paused view uses no content. These
  calls are still refused once access is revoked or out of scope.

A receiver that should end with the Host process registers with
`mutate(sequence, "observe-live", identity)`.

- The identity is 16 opaque bytes kept with the original request. It tells
  apart callers that pick the same next sequence at the same time.
- Only `OperationConflict`, which means another request owns that sequence,
  lets you pick a new sequence. After a lost answer, resend the original
  request.
- The attachment must have started and confirmed a live scope, which marks one
  run of the Host. When the next run starts a new scope, the previous scope's
  receivers close.
- Each new live registration frees one receiver left over from an old marker,
  clearing its access and retiring its durable names in the same transaction
  that adds the new one.

## Reading changes

The receiver accepts `poll()` or `receive()`, optionally with the last cursor
as one bytes argument. `poll` returns the current result at once. `receive`
waits if nothing has changed since that cursor.

The tagged `access:observation` reply holds, in order:

1. A 56-byte cursor.
2. The scoped use or control description.
3. A Boolean that is true when you must start over from the snapshot.
4. A Boolean that is true when something changed.
5. A list of notice symbols: `access`, `target`, `inventory`, `management`, or
   `subtree`.

Notices name the kinds of change kept in history. `subtree` means something
below the target changed: a child's content, or a child created, moved, or
deleted. Only a use whose own grant covers the target's subtree gets it, and
only that use's cursor moves with those changes. A narrower grant sees the
target alone.

One reply can sum up several commits along with a current snapshot of what
you may see. Each later call still checks current permissions.

The cursor belongs to one receiver and grants nothing by itself. To resume
after a disconnect or restart, keep the receiver's durable name and the
cursor.

- Commits to things you cannot see leave the cursor unchanged, even when you
  ask for a fresh snapshot without a cursor.
- If the history you could see has expired, the reply says to start over and
  includes the current snapshot.
- A paused or revoked use, or a control you can no longer use, sees only its
  status. Policy or content edits while paused do not move the cursor.
- Every reply checks current permissions, as ordinary calls do.

## Canceling

Call `cancel()` on the canceler to close the receiver. One transaction stops
the owner keeping it alive, clears its links and its sealing key, and retires
both durable names.

- After it closes, a canceler you still hold returns false, and resending the
  registration is refused instead of bringing it back.
- You can cancel while the receiver is waiting.
- If the cancel aborts, the receiver and its names stay.

## Limits and cursor sealing

Each owner allows at most <!-- value ../../src/loam/access/records/observation_index_record.zig capacity -->32<!-- /value --> receivers, and canceling one frees its place.
Each receiver keeps the exact grant it watches, an optional fixed resource
identity, a random 32-byte sealing key, and the point in history where it
started.

Loam tags each grant and resource with its revision and its place in the
commit order. The cursor encrypts only the position and digest that matter
to this receiver, using Zig's AES-128-SIV with the receiver's identity as
associated data, so raw revisions and owner counters never appear on the
wire. [ADR-0179](../decisions/adr/ADR-0179-scoped-change-retention-and-observation.md)
covers how long history is kept, privacy, and replay.

Limits on bindings, cache, leases, retentions, call memory, incoming calls,
and the transport are all separate. A receiver waiting in `receive` releases
its managed operation and leases, and a reply ready to send releases them
once it has copied its snapshot. How many receivers can wait at once depends
on all of those limits together, so deep resource paths need larger binding
limits, and limits too small to work are refused.

The largest-fanout test (`access observation maximum parked fanout` in
[observation_hosted_test.zig](../../test/loam/access/observation_hosted_test.zig))
keeps 32 receivers waiting with a cold cache, using:

- eight bindings per call
- 296 leases and 80 cache slots
- a 5 MiB cache budget and 168 retention slots
- 4 MiB of incoming-call memory
- a 128 KiB outgoing buffer limit and one 4 KiB reply per receiver

## From Zig

Zig code uses the opaque `storage.ObservationRegistration`,
`storage.Observation`, and `storage.ObservationCancellation` operations.

- Registration borrows a source `Operation` that has not been prepared yet,
  takes a target for use (or null for control) and a key your program
  supplies, and writes into the caller's Store transaction. Run the source's
  missing reads before you retry creating it, then run the registration's
  reads. The source stays open until the registration releases it.
- Polling and canceling start from a lease on a committed receiver. Polling
  returns values it owns, of bounded size, and canceling writes into the
  caller's transaction.
- A receiver with durable names needs the Host attachment to retire them, so
  Zig code cannot leave its names answering.
- Cancel submitted reads and wait for their completions before releasing
  operations.
