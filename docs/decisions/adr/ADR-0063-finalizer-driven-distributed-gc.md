---
id: ADR-0063
status: accepted
date: 2026-06-18
tags: [gc, bindings, memory]
decision: "A binding may opt a connection into finalizer-driven distributed GC: each far reference lifted from the wire owns one wire-count unit and enqueues one op:gc-exports delta when the language reclaims it; the feature is off by default and the sans-io core is unchanged."
supersedes: []
superseded_by: []
---

# ADR-0063 Finalizer-driven distributed GC

## Context

The wire-delta GC substrate already ships (ADR-0008,
`docs/protocol-diagrams/05-gc.md`): the session counts an import row up once per
wire occurrence of a `far` reference and down by `op:gc-exports` deltas,
releasing the row at zero, and the C ABI exposes `pancake_peer_send_gc_export` /
`pancake_peer_send_gc_answer`. The stateless host policy (`src/driver/core/gc.zig`)
drives it for a host that retains nothing. What no binding did was drive a
release _from a dropped application handle_: a long-lived session that lifts and
drops many imports kept their rows until teardown, because a binding's `Ref` had
no death rite.

This engages the **performance-is-a-public-contract** and
**explicit-over-implicit** principles. Distributed GC must not become a hidden
runtime that mutates the session behind the application's back, and it must not
weaken the core's no-I/O, deterministic shape. The languages disagree on _when_
a value dies (Rust `Drop` is prompt and deterministic; JavaScript
`FinalizationRegistry`, Python `weakref`, and Racket will-executors are
best-effort and run on their own schedule), so the design must be correct under
nondeterministic, possibly-never finalization.

## Decision

A connection may be opted into GC at construction (`gc` option, **off by
default**). When on, the `far` reference a `fetch` returns owns exactly one
wire-count unit and registers a language finalizer. When the language reclaims
the handle, the finalizer enqueues a single `op:gc-exports` delta of 1 for that
import position; the connection's serve loop drains that queue with mutable peer
access and calls `pancake_peer_send_gc_export`. Near references, promises,
sturdyrefs, broken references, the bootstrap import (position 0, which
send-validation refuses in a `gc-exports`), and redeemed-handoff tokens
(synthetic far ids the machine router mints, never wire imports) are never
registered.

`fetch` is the one tracked site because it is the same seam in every binding,
the connection mints the `Ref` itself, in one place, with full context: so the
feature is identical across the four. The other ways a far import reaches an
application (a reply lifted from a `send`, an argument lifted from an inbound
deliver, an `enliven` result) are deliberately *not* tracked: see Scope.

The per-handle-equals-one-unit rule is what makes the accounting exact without a
shared registry or identity dedup: the session added one count per wire
occurrence, the binding lifts each occurrence into exactly one finalizable
handle, and each handle releases exactly one. N occurrences cost N units and N
deltas; language-level sharing (an `Arc`, an object passed by reference) keeps
clones on the one unit, so a clone never double-releases. The resurrection race
(`05-gc.md` GC-3) stays benign: a re-import arriving as the last handle dies is
a fresh occurrence with its own fresh unit, and the delta the dying handle emits
is the one the session already counted.

Finalization is best-effort by construction. A delta that never fires (the
language never reclaims the handle, or the session closed first) costs a
stranded table row reclaimed at teardown, never a correctness fault, never an
underflow, because the binding only registers references the session actually
counted. The finalizer-to-serve-loop queue mirrors the one ADR-0012's enliven cache
uses in the Rust driver: a finalizer cannot reach the `!Send` peer, so it parks
the position on a shared queue the loop owns.

The sans-io core is untouched: this is adapter policy over the existing
`gc_export` message and the existing import-table accounting
(`session.importRefcount`, `applyGcExportDecrement`). Each binding owns its
finalizer idiom; the contract above is the same in all four.

## Scope (what this does not decide)

- GC stays **off by default** in every binding. A connection opts in; nothing
  changes for an application that does not.
- This does not add a `gc-answers`-from-finalizer path for dropped reply
  promises. Answer positions are single-reference and already released by the
  stateless policy and explicit `send_gc_answer`; a promise-handle finalizer is
  not wired.
- This does not change `src/driver/core/gc.zig`'s stateless-host policy, nor make the
  native Zig `driver.Session` register finalizers (Zig has no finalizers; a
  Zig consumer calls `sendGcExport` explicitly).
- It does not promise prompt collection. A binding inherits its language's
  finalization timing; only Rust's `Drop` is deterministic.
- Only a `fetch` result is tracked. A capability lifted from a `send` reply, an
  inbound deliver argument (e.g. Rust's context-free `Ref::try_from`), or any
  other path is outside this seam: released when the session tears down, as
  before. Tracking those uniformly across the four bindings is a later lift; the
  asymmetry of doing it in some but not others is the worse outcome.
- An `enliven` result is not tracked. The ADR-0012 dedup cache deliberately
  retains the import so a repeat enliven of the same swiss-number short-circuits;
  a finalizer that released it on handle drop would invalidate the very cache
  entry the next enliven expects to hit. The cache owns that import's lifetime.

## Alternatives Considered

- **A shared position-to-proxy weak registry** (the Goblins shape: one proxy per
  import, finalizer emits the position's whole accumulated delta). Rejected as
  the default: it couples GC to capability-identity dedup and a per-connection
  weak map in every binding, more machinery than the per-handle rule needs for
  exact accounting. The per-handle rule reaches the same wire result with no
  registry.
- **Explicit `release()` only, no finalizers.** Rejected: it pushes the
  bookkeeping the language's GC already does back onto the application, the
  exact footgun the binding exists to remove. (The explicit C ABI call remains
  for the Zig/power-user path.)
- **On by default.** Rejected: a hidden release on every dropped handle is a
  hidden runtime mutating the session; opt-in keeps the authority explicit.

## Consequences

- Each binding gains a `gc` connection option, a finalizer registration on
  lifted far references, and a drop queue the serve loop drains. The lift path
  centralizes through one helper so every wire-sourced import is registered
  once.
- `test/engine/gc_churn_test.zig` gates the session invariant the finalizers
  drive: a session that imports and releases the same position many times holds
  flat heap and returns `importRefcount` to zero: the proof the dropped-handle
  path reclaims rows.
- The binding dogfoods each prove a lifted import, once dropped, emits the
  `op:gc-exports` the partner needs to release its export.

## Notes

Builds on ADR-0008 (wire-delta GC profile) and reuses the finalizer-to-loop queue
shape introduced for ADR-0012's enliven dedup cache.
