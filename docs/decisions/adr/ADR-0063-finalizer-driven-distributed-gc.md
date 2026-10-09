---
id: ADR-0063
status: accepted
date: 2026-06-18
tags: [gc, bindings, memory]
decision: "A binding may opt a session into finalizer-driven distributed GC: every capability occurrence projected into application data by that session owns one Host release unit, and its language finalizer returns that unit through glowcap_host_ref_release; the feature is off by default, failure stays at the Host barrier, and the wire-delta core remains runtime-neutral."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0192]
---

# ADR-0063 Finalizer-driven distributed GC

## Context

The wire-delta GC substrate already ships (ADR-0008,
`docs/protocol-diagrams/05-gc.md`): the session counts an import row up once per
wire occurrence of a `far` reference and down by `op:gc-exports` deltas,
releasing the row at zero, and the C ABI exposes `glowcap_peer_send_gc_export` /
`glowcap_peer_send_gc_answer`. The stateless host policy (`src/driver/core/gc.zig`)
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

A session may be opted into GC with its binding's `with_gc` / `withGc` verb
(**off by default**). The opt-in applies at the application-projection seam:

- a `fetch` result;
- a fulfilled far `send`, `listen`, or projection result; and
- every capability nested anywhere in an inbound delivered argument, including
  a redeemed handoff promise.

Each occurrence receives one language finalizer before application code, a vow
waiter, or the bounded unobserved-outcome store can retain it. The policy is
sampled when the operation is minted, or when the inbound turn begins; changing
the opt-in later does not rewrite an already-admitted value's ownership.

The finalizer carries only the opaque Host capability id. It parks one release
unit on Host-owned state, outside the collector callback, and the binding's
ordinary runtime/pump thread invokes `glowcap_host_ref_release`. The Host alone
decides whether that identity releases a local root, a direct import, or a
routed handoff and emits any required `op:gc-exports`. Bindings do not inspect
id ranges or duplicate routing policy.

The per-occurrence-equals-one-unit rule is what makes the accounting exact
without a binding-side identity registry: native projection owns one Host
retain for each capability leaf, the binding lifts each leaf into exactly one
finalizable handle, and each handle releases exactly one. For a far import,
N wire occurrences cost N import-count units and eventually N deltas;
language-level sharing (`Rc`, or an object passed by reference) shares the one
guard, so a clone never double-releases. The resurrection race
(`05-gc.md` GC-3) stays benign: a re-import arriving as the last handle dies is
a fresh occurrence with its own fresh unit, and the delta the dying handle emits
is the one the session already counted.

Finalization is best-effort by construction. A release that never fires (the
language never reclaims the handle, or the Host closes first) leaves ownership
to deterministic Host/session teardown; it never becomes a correctness fault
or an underflow. A finalizer cannot drive a `!Send` Host or cross an FFI boundary
from a collector thread, so it only parks the id and schedules ordinary Host
progress.

Session teardown makes every remote capability homed there unusable at once,
but preserves a release-only Host row containing only the opaque id and the
already-issued application-retain count. A later finalizer therefore consumes
its exact unit as a wire-free success instead of retrying `UnknownCapability`
forever. The row disappears with the final unit; its retained population is
bounded by handles that existed when the session closed, and it cannot be used,
canonicalized, or projected onto another session.

Release is transactional with respect to failure. A parked id leaves its queue
only after `glowcap_host_ref_release` commits. A refusal retains that id and its
tail for retry, and an unowned scheduled-drain failure reaches the binding's
existing Host failure recipient rather than escaping a finalizer or changing a
protocol outcome. Explicit `release` uses the same C verb, disarms the
finalizer only after success, and preserves the handle on refusal.

The wire-delta session machinery stays runtime-neutral: this is adapter policy
over the existing `gc_export` message and import-table accounting
(`session.importRefcount`, `applyGcExportDecrement`). Each binding owns its
finalizer idiom; the contract above is the same in all four.

## Scope (what this does not decide)

- GC stays **off by default** in every binding. A session opts in; nothing
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
- Fresh and cached session `enliven` results are tracked when the session opts
  in. Each projected occurrence owns an application retain; a cache hit can
  issue another retain without another wire fetch. Releasing one occurrence
  preserves the others. The final release retires the Host identity and the
  matching cache/import state; another enliven fetches a fresh occurrence.
  Host-level calls have no GC-enabled arrival session and require explicit
  application release. `bindings/rust/src/session_tests/enliven_gc.rs` exercises
  cached sharing, final release and fresh enlivenment over the real Host.
- Locally created handles (`spawn`, `publish`, and `published_ref`) are not
  enrolled merely because a session has opted in. Their explicit actor and
  publication roots own them. A local capability returned through a tracked far
  outcome is enrolled because that occurrence crossed the application
  projection seam and owns its own Host retain.

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

- Each binding has one recursive application-value tracker and one Host-owned
  drop queue. The tracker is binding plumbing over the common Host release
  authority; no language binding decides wire identity or GC accounting.
- `test/engine/gc_churn_test.zig` gates the session invariant the finalizers
  drive: a session that imports and releases the same position many times holds
  flat heap and returns `importRefcount` to zero: the proof the dropped-handle
  path reclaims rows.
- Rust, TypeScript, Python, and Racket dogfoods prove nested fetch results,
  fulfilled send results, and delivered arguments in both wire directions. The
  release is observed before close, so teardown cannot satisfy the proof by
  accident.

## Notes

Builds on ADR-0008 (wire-delta GC profile) and reuses the finalizer-to-loop queue
shape introduced for ADR-0012's enliven dedup cache.
