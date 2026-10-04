---
id: ADR-0186
status: accepted
date: 2026-10-03
tags: [loam, browser, bindings, storage, ownership]
decision: "Browser storage evaluates shared Zig transactions through bounded transaction-local KV callbacks, retains custody until IndexedDB retirement, and holds an exclusive Web Lock."
supersedes: []
superseded_by: []
amends: [ADR-0185]
amended_by: []
---

# ADR-0186 Loam browser transaction execution

## Context

The first foreign resource profile has portable Store and Host owners, but its
LMDB executor cannot run in a browser. [IndexedDB's transaction lifecycle](https://www.w3.org/TR/IndexedDB/#transaction-lifecycle)
permits dependent requests during active request events and reports commitment
through a terminal event.
Moving validation into JavaScript would duplicate transaction, identity and
managed authority laws. This decision preserves the sync no-I/O core, explicit
custody and one authority per fact established by ADR-0161 and ADR-0185.

## Decision

The portable C archive evaluates submitted effects through synchronous,
transaction-local get, put and remove callbacks. The evaluator invokes the
existing Zig batch application, name lookup, read validation and recovery.
A missing row suspends evaluation. The adapter discards tentative writes,
loads that row, and evaluates again in the same atomic transaction.
Returned row borrows remain valid throughout each evaluation call.

Evaluation publishes a plan only after every fallible calculation succeeds.
The adapter reports completion, known abort or an indeterminate write after
physical transaction retirement. Host-thread installation consumes that outcome
through the existing Store tickets. An aborted recovery drops its tentative
result and preserves the original barrier. Recovery reads the exact committed
receipt; it never submits another write to settle uncertainty.

Rust retains one transaction task and its callback through IndexedDB's terminal
event. An observer can disappear while that owner continues. Creation retains
its provisional result for later observation; attachments retain content contexts
through all work and successful detach. These are existing Host owners and the
embedding executor, with no additional actor runtime.

Each database opening holds an exclusive, non-stealing
[Web Lock](https://www.w3.org/TR/web-locks/#api-lock-manager) and atomically
claims a new Store incarnation. Every batch checks that incarnation and revision.
Writes require confirmed strict IndexedDB durability. Missing locking, unknown
schema, quota refusal or identity mismatch fails explicitly. Reopening cannot
create an empty database or reset authority. Browser eviction and origin access
remain embedding constraints.

## Scope

The browser projects the same fixed-resource lifecycle as the first C/Rust
profile. General graph editing, saved-reference authoring, collection cursors
and privileged owner lifecycle remain broader consumer projections. Rooms
application replacement and its archive/blob custody are separate integration
work. This proof establishes browser execution, not OS target support or
outside-peer protocol conformance.

## Alternatives considered

- A browser transaction evaluator creates another owner of record and grant laws.
- Loading all rows before evaluation makes resident cost grow with store size.
- Waiting across arbitrary asynchronous tasks inside a transaction loses the
  IndexedDB activity window.
- Releasing callbacks when an observer disappears can strand a live transaction
  or let it use released C buffers.

## Evidence and checks

`test/c_abi/loam_execution_test.zig` proves suspension without publication,
commit-gated installation, exact unknown-write recovery, aborted recovery retry
and unchanged mutation. `loam-abi-test` runs it under `check`.

`loam-browser-test` drives the linked Rust/C consumer in Chromium. It exercises
sharing, narrowed admission, edits and receipt replay, ancestor pause/resume,
page reload and cold publication discovery. It also proves exclusive custody,
callback retirement, observer abandonment, mid-batch quota rollback, mutation retry after refusal, and unrelated
actor progress during blocked storage. Adapter statistics expose bounded
snapshot and overlay bytes, database requests, evaluation passes and copies.
The proof belongs to `check-external`; `check` validates generated Wasm layouts
against the actual compiled C archive.
