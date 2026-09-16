---
id: ADR-0160
status: accepted
date: 2026-09-14
tags: [rooms, performance, ownership]
decision: "Rooms correlates retained posts and reuses acknowledged immutable uploads within existing bounded custody."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0160 Rooms retained delivery

## Context

A sender already holds the message it uploads. Returning the complete text
and downloading its own files repeats wire traffic and materialization.
Suppressing the sender's notification would also remove authoritative ordering,
canonical captions, attachments, and the association with editable line authority.
This decision applies the project's allocation and ownership principles at the
Rooms application boundary. It changes no CapTP or transport semantics.

## Decision

Native rooms advertise `retained` in their existing `carries` notice. A sender
opts into retention for each request. The server chooses the sender's receipt
during the ordinary subscriber traversal, using the exact membership and calling
connection. Delegating a membership to another connection still authorizes a
post and produces complete notifications for subscribers.

The sender reserves a single-use identity before asynchronous file staging.
Its pending text and unread messages share the existing 256-message, 2 MiB
budget. An ordered receipt moves the retained string into the unread queue.
The receipt includes authoritative line identity, nickname, preview selection,
attachments, and any normalized caption. The request answer continues to grant
line edit authority separately. Cancellation of an awaiting future does not
drop the membership's pending body. Closing its consumer drops both pending
and unread messages.

Retained verbs refuse before committing a post. A refused send admission releases
its unsent body immediately and preserves that local verdict for the runtime.
Once admitted, both acceptance and rejection complete through the membership's
inbox. `receiptRejected(request)` releases text even after its reply observer
was cancelled or timed out. Transport loss leaves the payload available for a
late completion until membership closure. A broken promise alone does not decide
whether a post committed. This protocol does not retry or deduplicate mutations.

Cancellation also removes the runtime's correlated line-authority reservation.
An uncertain legacy request resynchronizes its membership before accepting
another send. Without correlation, either keeping or removing its FIFO slot
could give a later line the wrong edit authority. Only legacy sends retain a
recovery notifier; correlated sends add no channel clone.

An optimized attachment admission returns both upload authority and its read
capability. The server reuses each live blob capability within its receiving
connection. The sender can therefore associate its immutable upload capture
with the same media-pool row the authoritative notification will name.
Materialization waits for upload acknowledgement, and failed uploads remain
failed. Shared capture clones retain one chunk index without copying bytes.
Admission follows a successful post or refile answer, uses the existing bounded
cache, and protects files selected for a refile. The existing per-membership
file-batch owner holds a matching refile event until its publication attempt
settles. Rejection and cancellation wake that event without evicting old media.
This ordering needs no candidate payload queue or additional byte budget.
When a refile keeps any old files, admission protects all at most eight known
attachments: a delegated refile may have changed index meanings in a queued
event. Partial replacement can therefore reach the ordinary-read fallback
sooner under pressure. Replace-all needs no such protection. Failure to admit
reuse falls back to ordinary reads.

## Scope

Edit and withdrawal notifications retain their full authoritative broadcasts:
their capabilities may be delegated independently of membership. Peers without
the advertised extension use the existing post and attachment methods.
Streaming sources without an immutable capture also use ordinary remote reads.
The bounded outgoing chunk copy required by the binding's owned byte argument
remains. This decision adds no compression or content-addressed global cache.

## Costs

Absent text and preview fields use the scalar `false`. CapTP's void value is
a record and costs more bytes here. The normal receipt path retains one text
copy before sending, then transfers it into the unread queue without copying.
A single-use request holds a weak reference to its membership and allocates
nothing. Pending metadata uses a bounded deque, reusing its capacity. Presence,
room facts, and local correlation share one mutually exclusive metadata slot.
The native queued-message footprint falls from 224 to 176 bytes, with a checked
ceiling rather than an added allocation to move those fields elsewhere.
Rejection adds one token-only callback; successful posts add no cleanup task or
callback. Admission errors reuse the binding error's existing boxed storage.
Preview selection decoding checks the five-URL count before materializing another
entry and limits encoded JSON to 61,457 bytes, enough for fully escaped maximum
URLs. Ordinary selections keep the same serialization and allocation shape.

Native trace measurements count the actual request and callback frames; the
unchanged line-authority answer is outside this projection. At request zero,
an 8 KiB text exchange falls from 16,598 to 8,389 bytes. Empty text falls from
206 to 192 bytes. At the maximum supported request identity, empty text instead
costs 222 bytes, a 16-byte increase that buys exact correlation. Tests include
both extremes and bound the overhead instead of assuming every message saves.

Each chunked capture gains one shared-index allocation, making subsequent
capture clones independent of chunk count. Each optimized upload has one
acknowledgement channel. The bounded connection-local reader inventory spends
one entry per live file identity to reuse capability exports and receiver bytes.

## Alternatives considered

- Suppressing the sender's notification loses authoritative ordering and state.
- Matching text or nickname cannot distinguish concurrent or delegated posts.
- A second unbounded payload cache moves network cost into retained memory.
- Reading the server's copy of an acknowledged immutable upload repeats bytes
  already held by the sender. Reusing a mutable source would change semantics.

## Evidence and gate

Application receipt scenarios cover exact subscriber selection, canonical fields,
delegation, edits, and withdrawals. Client tests cover pointer-preserving text
transfer, correlation, combined capacity, and close. Native service tests exhaust
the old leak paths with locally refused and abandoned rejected requests and measure
actual encoded request and callback lengths. Media tests check a 1 MiB
capture's shared storage, zero remote reads, acknowledgement, failure, pressure,
and shutdown. The native Rooms journey checks stable file identities on refiles.
Native runtime scenarios exhaust the authority-slot ceiling with cancelled
retained refusals, and cancel both accepted and refused legacy replies. They
verify that only legacy memberships rejoin and that recovered line authority
actually edits the corresponding line. These run through
`zig build runtime-check`; `zig build check` covers the repository's static and
in-process contracts.
