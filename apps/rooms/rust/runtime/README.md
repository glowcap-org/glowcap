# rooms-runtime

This crate executes the Rooms application through supplied platform effects.
The process peer and browser workspace consume the same managed session owner.
Application declarations live in `rooms-application`, capability clients in
`rooms-glowcap`, and grant semantics in shared Loam. Read the
[session guide](../../../../docs/rooms/session.md) for production composition and
[effect contract](../../../../docs/rooms/session-effects.md) for admitted work.

## Embedding a session

The embedding supplies a Host, registered Loam Store, task custody, deadlines,
clocks and entropy. LMDB and IndexedDB adapters supply the same storage contract.
`managed::Bootstrap` persists identity, resource metadata and live markers;
`managed::Opened` retains the Store, attachment and session through shutdown.
Opening restores bounded owner metadata, checks the codec graph and retires
previous Host registrations before exposing separate use/control branches.

The process storage composition in `rooms-platform::storage::session` uses the
state-directory lease and atomic bootstrap metadata replacement. The browser
composition in `rooms-browser::storage::Session` uses per-tab IndexedDB and an
exclusive Web Lock. Neither startup loads every grant or reconstructs custody
from a descriptive snapshot.

Use `Opened::workspace` and `Opened::management` for typed clients.
`Opened::supervise_workspace` starts workspace-driven membership activity.
Publication prepares reachability on demand; local calls need no transport.
Stop activity before closing the session. Failed close retains complete custody
for retry, and the Host stays alive until its barriers succeed.

## Runtime owners

Modules below live under `session::managed` unless another owner is named.

| Owner | Responsibility |
| --- | --- |
| `content`, `records`, `imports` | Source-checked callbacks, registered pages and atomic custody acquisition. |
| `executor`, `retained`, `results` | Committed receipt dispatch, exact retained outcomes and private settlement. |
| `coordination`, `watching`, `supervision` | Membership registry, workspace observation and worker retirement. |
| `realization`, `inbox` | Exact initiating source, installed callbacks, registration and subscription. |
| `introductions`, `received_lines` | Reciprocal direct routes, introduction witnesses and posted-line custody. |
| `discovery`, `signaling` | Bounded directory reads and registered-name/source admission. |
| `uploads`, `outgoing` | Immutable submissions, source leases, room filling and direct reader scopes. |
| `recording`, `archive_sharing` | Recorder admission, pending erasure and exact archive share effects. |
| `bridge`, `session::bridge_secrets` | Private credential acquisition, witnesses and scoped retention. |
| `activity`, `changes` | Bounded observations and wake delivery, including terminal executor progress. |
| `profile` | Composed graph, continuation, reader and production storage budgets. |
| `archive` | Bounded records, capture queues, scoped readers and backend execution. |
| `files` | Selected source custody, leases and immutable delivery plans. |
| `trace` | The application trace consumer and transport. |

A caller dropping its wait abandons observation while admitted work stays owned.
External replies distinguish failure before target admission from uncertainty
after it. Durable receipts own application outcome and recovery. Shutdown drains
callbacks and upstream name/seat custody; an unknown subscription cannot be
cleaned up by assuming absence.

Storage adapters keep admitted work alive when its observer stops waiting.
An uncertain storage write is reconciled before protected execution resumes.
Concrete storage and transport causes remain available at the typed failure
boundary. The crate itself performs no filesystem, socket or browser I/O.

## Evidence and cost

`rooms-rust-test` runs the shared executor on Linux with real LMDB reopen.
`rooms-session-executor-browser-test` runs the same scenarios on Chromium
with IndexedDB, including retained foreign results through physical recovery.
Production page proofs add shared drafts, files, startup, process restart,
reconnect and access management. The [measurement report](../../../../bench/rooms/session-costs.md)
records allocation and traversal counts, including wake snapshot reuse.
