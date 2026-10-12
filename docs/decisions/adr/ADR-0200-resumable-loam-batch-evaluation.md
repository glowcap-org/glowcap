---
id: ADR-0200
status: accepted
date: 2026-10-04
tags: [loam, browser, storage, ownership, performance]
decision: "One resumable core batch evaluator emits synchronous writes into the same atomic transaction and retains no backend row across a missing read."
supersedes: []
superseded_by: []
amends: [ADR-0186]
amended_by: []
---

# ADR-0200 Resumable Loam batch evaluation

## Context

Retained content graphs can require more physical rows than the browser
adapter's fixed snapshot and write inventories admit. Restarting batch
application for every missing row repeats fingerprinting, validation and
tentative writes, while retaining every loaded row increases memory with
transaction size. Raising those inventories keeps both costs.

The existing core already owns record laws, names, collection barriers and exact
recovery. IndexedDB already owns atomicity and serializes put values during the
synchronous request call. The boundary uses both owners directly.

## Decision

`Batch.Evaluation` is the shared evaluator for synchronous backends and
asynchronously supplied transaction rows. Its cursor holds counters, positions
and views into immutable batch bytes. Those bytes and the batch stay at stable
addresses until the evaluator retires. A backend row is consumed before the
next callback and never retained across suspension.

Only get may report an unloaded row. The next evaluation resumes at that read
in the same physical transaction. Put and remove synchronously consume their
key and value. Earlier writes remain queued in that transaction. They are
neither discarded nor repeated. A write refusal is terminal and requires
physical abort. Later name or collection barrier failures also abort the
complete transaction. Metadata emission does not install a Store revision.

The browser retains a fixed metadata input and one supplied row. Metadata is
kept because the existing read, name lookup and restore fronts need metadata
and one row together. A write copies directly into owned JavaScript byte
arrays, which IndexedDB serializes before Rust invalidates a matching input.
The next queued read observes preceding writes in the same transaction.
JavaScript retains one pending read request and clears its callback before
resumption. Rust retains no write overlay or growing row inventory.

The encoded-record limit is configured through C and Rust. Input memory derives
from that limit, fixed metadata, bounded physical keys and fixed Plan state.
Core staging, mutation, edge and retained-call limits bound transaction work.
IndexedDB's queued write values, cache and origin quota remain browser-owned
costs. Statistics expose retained input, copied bytes, emitted writes and
cumulative submitted write bytes separately.

Browser close joins Web Lock retirement before reporting success. Rust retains
the close task if its observer disappears. The same ownership applies to
failed-open cleanup, so immediate reopen does not race a prior lock release.

Physical browser tasks retain JS callbacks until the terminal event, independent
of the embedding's Tokio LocalSet lifetime. A finite delivery task admitted on
the existing LocalSet owns Host completion before I/O starts. Physical tasks
transfer raw Work or separately retained capability occurrences. They never
construct scheduler-dependent reference guards or schedule Tokio cleanup.
Restoration's two raw occurrence IDs transfer into caller-side guards only on
consumption. Abandonment parks every occurrence, then acknowledges the relay
so it drains the pending releases. The acknowledgement covers buffered results
after a successful send. Physical attachment custody and the Host task barrier
end at terminal completion, so an unpolled result cannot block retirement.
Completed outcomes are delivered before unrelated Host progress. Destroying
the LocalSet preserves physical callbacks and parked obligations, which need
later explicit Host progress. It never creates another runtime.
Completion errors are captured before Work release clears the C diagnostic.
Idle attachment progress reclaims released endpoint boxes through an ordinary
Vat boundary when the Vat reports retired state. This frees their fixed slots
on the Host executor without requiring another application invocation. The
idle predicate is constant time. Physical restore callbacks never drive it.

C keeps the cursor inline in its startup Store or fixed Work slot. The executor
owns each submitted Work until physical retirement. Callback reentry cannot
evaluate, finish or release that Loam owner. A thread-local stack of fixed
evaluation frames owns this guard, so independent workers and Host progress
share no guard state. Host-thread installation and
retirement still require the executor to have joined. The callback guard is
not a thread synchronization or cancellation mechanism.

This amends ADR-0186's discard-and-replay policy and its row-borrow lifetime.
Terminal event custody, strict durability, exclusive opening and exact receipt
recovery remain unchanged. Collection cursor submission still requires
synchronous KV walks and is outside the browser C profile.

## Alternatives considered

- Larger snapshot and overlay inventories retain transaction-sized memory and
  repeat whole-batch work at each miss.
- A Rust or JavaScript batch engine would duplicate record and authority laws.
- New cursors for read, lookup and restore would remove a tiny fixed metadata
  input while multiplying lifetime state across otherwise stateless fronts.
- Suspending writes could repeat a partially emitted name or mark queue change.

## Evidence and limits

Core tests suspend every read while invalidating backend borrows, and refuse
every emitted write, including name installation and mark queue helpers. They
check exact record accounting, shared target marking and terminal refusal.
C tests preserve emissions across suspension and reject callback reentry.
The Chromium lifecycle and real Rooms session graph proofs cover commit,
quota abort, retry, cold restoration and full page reload.
Browser restoration also exercises blocked cancellation, buffered abandonment
and reuse of two endpoint slots on a live Host, buffered outcomes through Host
close, partial restoration and LocalSet teardown before terminal retirement,
then later cleanup. These cases do not measure cleanup latency or independent
Store progress under separate storage blockers.

The cursor removes batch replay. Duplicate-mutation and in-batch target searches
still scan the bounded batch. This decision does not establish globally linear
evaluation, the full Rooms capacity profile or guaranteed browser storage quota.
