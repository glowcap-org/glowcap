# rooms-runtime

This crate executes the Rooms application through supplied platform effects.
The process peer and browser workspace consume the same managed session owner.
Application declarations live in `rooms-application`, capability clients in
`rooms-glowcap`, and grant semantics in shared Loam. Read the
[session guide](../../../../docs/rooms/session.md) for production composition and
[effect contract](../../../../docs/rooms/session-effects.md) for admitted work.

## Embedding a session

The embedding supplies a Host, registered Loam Store, task spawning, deadlines,
clocks and entropy. Every Loam disk engine and IndexedDB supply the same storage
contract.
`managed::Bootstrap` persists identity, resource metadata and live markers.
`managed::Opened` retains the Store, attachment and session through shutdown.
Opening restores the saved owner records, checks that the stored types still
decode, and retires the previous Host's registrations. Only then does it hand
out the separate use and control handles.

The process storage composition in `rooms-platform::storage::session` uses the
state-directory lease and atomic bootstrap metadata replacement. The browser
composition in `rooms-browser::storage::Session` uses per-tab IndexedDB and an
exclusive Web Lock. Neither loads every grant at startup or rebuilds storage
from a summary.

Use `Opened::workspace` and `Opened::management` for typed clients.
`Opened::supervise_workspace` starts workspace-driven membership activity.
Publication prepares reachability on demand. Local calls need no transport.
Stop activity before closing the session. A failed close keeps everything
it holds for a retry, and the Host stays alive until its barriers succeed.

## Runtime owners

Modules below live under `session::managed` unless another owner is named.

| Owner | Responsibility |
| --- | --- |
| `content`, `records`, `imports` | Source-checked callbacks, registered pages and atomic storage acquisition. |
| `executor`, `retained`, `results` | Committed receipt dispatch, exact retained outcomes and private settlement. |
| `coordination`, `watching`, `supervision` | Membership registry, workspace observation and worker retirement. |
| `realization`, `inbox` | Exact initiating source, installed callbacks, registration and subscription. |
| `introductions`, `received_lines` | Reciprocal direct routes, introduction witnesses and posted-line storage. |
| `discovery`, `signaling` | Bounded directory reads and registered-name/source admission. |
| `uploads`, `outgoing` | Immutable submissions, source leases, room filling and direct reader scopes. |
| `recording`, `archive_sharing` | Recorder admission, pending erasure and exact archive share effects. |
| `bridge`, `session::bridge_secrets` | Private credential acquisition, witnesses and scoped retention. |
| `activity`, `changes` | Bounded observations and wake delivery, including terminal executor progress. |
| `profile` | Composed graph, continuation, reader and production storage budgets. |
| `archive` | Bounded records, capture queues, scoped readers and backend execution. |
| `files` | Selected source ownership, leases and immutable delivery plans. |
| `trace` | The application trace consumer and transport. |

A caller that stops waiting stops watching, but work already admitted keeps
its owner and runs on. A reply from another peer says whether the call failed
before that peer took it or whether the outcome is unknown. Durable receipts
hold what happened and how to recover. Shutdown drains callbacks and releases
the names and seats this session holds upstream. A subscription in an unknown
state is never treated as gone.

A storage write with an unknown outcome is settled before protected work
resumes. Failures keep their concrete storage or transport cause in the typed
error. The crate does no filesystem, socket, or browser I/O of its own.

## Tests and cost

`rooms-rust-test` runs the shared executor on Linux with real SQLite reopen.
The storage proofs that reopen a session store also run on LMDB.
`rooms-session-executor-browser-test` runs the same scenarios on Chromium
with IndexedDB, including retained foreign results through physical recovery.
Production page proofs add shared drafts, files, startup, process restart,
reconnect and access management. The [measurement report](../../../../bench/rooms/session-costs.md)
records allocation and traversal counts, including wake snapshot reuse.
