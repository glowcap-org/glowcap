---
id: ADR-0163
status: accepted
date: 2026-09-14
tags: [loam, persistence, actors, memory]
decision: "Attach bounded record-backed actors to the existing Host/Vat, restoring local capability edges lazily and withholding mutation replies until storage commits."
supersedes: []
superseded_by: []
amends: [ADR-0162]
amended_by: [ADR-0164, ADR-0165, ADR-0182]
---

# ADR-0163 Record-backed sleepy actors

## Decision

`glowcap.loam.hosting` is a portable integration module above `loam_core`,
`actors`, and `driver_core`. It attaches a Store to an existing Host, queues
ready work through the Vat, and emits explicit storage requests for the
embedding's executor. It owns neither a second scheduler nor database I/O.
Ordinary volatile actors require no attachment or additional per-session state.

A schema/version selects an explicit behavior callback. Its record is the
complete durable state; invocation reads immutable fields, obtains held local
capabilities from stored strong edges, and optionally proposes replacement
payload. Invocation performs no I/O or external effects. It receives no Turn
API for sending effects before commitment. This is a trusted native callback
contract, not memory isolation or automatic serialization of arbitrary actors.

The attachment retains plain-data requests in bounded call buffers. It preserves
per-actor pending-call order and coalesces loads through the Store. Ready work
uses the original Vat ingress; network work resumes through Host scheduling.
Cancellation of queued activation releases its lease. Outstanding backend work
retains its buffers until completion even when a caller disconnects. Existing
Host pending-work leases prevent shutdown from outrunning unfinished calls.

Replies to mutations wait for the commit outcome. Unknown outcomes retain
recovery ownership and fence Store use. Settlement may retry without repeating
the invocation or mutation. Both fulfilled and broken local resolver outcomes
prepare their owned callback data before consuming settlement authority.
The shared driver checks for pending local deliveries after encoding, because
encoding a deferred resolution can make a pipelined call runnable.

Sleeping releases eligible record bytes while ordinary Vat/Host custody keeps
held actor references callable. Stored objects alone allocate no endpoints.
Near calls require current resident state and cannot mutate durable state;
eventual calls provide the storage boundary. Retaining a committed record moves
its prepared allocation into available cache space, with no allocation during
installation and no displacement of pinned snapshots. The default policy uses
bounded cache residency; an every-turn policy stresses cold activation.

## Capability and publication boundary

Administrative restoration uses a checked current record lease. Saving a
capability requires held Host authority for an endpoint in this attachment.
A stored strong edge restores that exact target without recursively loading
its state. Raw record identifiers never replace held authority on the remote
call surface. Unsupported foreign and live-only capabilities refuse persistence.

A publication descriptor stores secret-name entropy and an exact actor edge.
The application retains bootstrap descriptor names and restores Host identity
at startup. A committed descriptor populates the existing Host publication
registry. Retirement replaces it with a tombstone and removes discovery from
that registry; previously issued references remain valid. Historical leases
cannot restore current authority. The embedding pauses fetch admission across
retirement commit and registry application, including unknown-outcome recovery.
No automatic publication enumeration or snapshot-based authority rollback is
introduced.

## Evidence and boundaries

`test/loam/hosting` covers near/far sleep/wake, lazy cyclic edges, admission
bounds, coalesced loading, corruption, cancellation, retained pins, closing,
allocation refusal, and cold object growth without endpoint allocation.
`loam-actors-crash-test` sends SIGKILL before native LMDB commit and after commit
before local installation. A fresh process restores the publication, calls the
actor through CapTP, and follows the saved cycle back to the same capability.
This proves those process boundaries, not power-loss behavior or external
protocol interoperability.

Pending calls and replies remain volatile; a caller can lose a reply after its
mutation committed. Durable inbox/outbox, retry receipts, events, managed grant
participants, foreign/cross-vat restoration, browser storage,
and C/Rust APIs remain in the [Loam plan](../../planning/loam/architecture.md).
Payload replacement currently preserves edges; administrative transactions
update them separately while no actor calls are pending. Timers, subscriptions,
unresolved promises, and native handles have no durable representation in this
profile. Local plain Vat responses cannot transport owning capability values;
those replies use the Host/CapTP path.

Fixed operation and endpoint tables use bounded linear searches; pending-call
ordering can take quadratic work in the configured call limit. Commit installation
checks bounded cache slots against changed objects while preserving lease epochs. These
costs and the separate Host, cache, staging, backend, and OS memory budgets must
be measured before claiming throughput, tail latency, or the live-session target.
The [Loam guide](../../loam.md) owns API use and lifetime requirements.
