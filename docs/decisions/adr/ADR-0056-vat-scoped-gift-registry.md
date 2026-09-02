---
id: ADR-0056
status: superseded
date: 2026-06-11
tags: [handoff, three-party, gift-registry, engine, session]
decision: "The vat-scoped `engine.bootstrap.gifts.GiftRegistry` is the single gift and handoff-count authority. The session's gift tables and gift methods are deleted; every `Peer` owns a private registry and a host serving several direct sessions to one vat shares one across its peers. Re-depositing a gift id replaces the prior row (replay stays blocked by the monotonic handoff count). A `withdraw-gift` whose gift has no live deposit parks on the peer and settles once the deposit lands. The registry carries no lock: the engine is externally synchronized, and a host that shares a registry across threads owns the locking."
supersedes: [ADR-0009]
superseded_by: [ADR-0100]
amends: []
amended_by: [ADR-0096]
---

# ADR-0056 Vat-scoped gift registry is the single handoff authority

> Superseded by [ADR-0100](ADR-0100-session-owned-handoff-authority.md). The
> cross-session premise here was wrong: the Exporter resolves the still-live
> Gifter–Exporter session and reads that session's gift table, as OCapN and
> Goblins specify. This record remains the history of the displaced design.

## Context

Three-party gift authority existed twice. The session carried per-session
`gifts` / `handoff_counts` tables with deposit / withdraw methods
([ADR-0009](ADR-0009-three-party-handoff-substrate.md) § Session-owned gift
table), and `engine.bootstrap.gifts.GiftRegistry` carried the same tables vat-scoped,
because a gifter deposits on its own session while the recipient withdraws on a
_different_ session: the per-session table cannot serve the spec's
cross-session flow. The engine dispatcher branched between the two at runtime,
`bootstrap.zig` carried duplicate resolve/verify pairs, and the duplicates had
drifted: the session rejected a duplicate gift id while the registry replaced
it. One authority had to win.

Engages the [First Principles](../../../AGENTS.md#first-principles): _session
state is authoritative_ is clarified, not relaxed: the session spine still
validates handoff well-formedness and the generic inbound path still moves no
withdrawal authority; the registry is vat-scoped authority that only the
verified callers consult. _Conformance is load-bearing_: the upstream suite and
`test/engine/gift_registry_test.zig` / `test/engine/cross_peer/` exercise this
registry directly. The live Goblins recipient and gifter checks cover adjacent
wire roles; glowcap is not the exporter-side registry in those checks.

## Decision

`engine.bootstrap.gifts.GiftRegistry` is the only gift / handoff-count authority.
Every `Peer` owns a private registry (`Peer.own_gift_registry`, freed in
`deinit`); a host serving several direct sessions to one vat points its peers at
one shared registry through `Peer.shared_gift_registry`, and
`Peer.giftRegistry()` selects whichever applies: the runtime dispatch branch is
gone. The session's `gifts` / `handoff_counts` tables, `GiftEntry`, and every
session gift method are deleted; `SessionLimits` keeps the `max_deposited_gifts`
/ `max_seen_handoff_counts` bounds the registry enforces
([ADR-0025](ADR-0025-session-table-cap-policy.md)).

The registry's semantics win where the two had drifted: re-depositing an
existing gift id replaces the prior row, freeing its keys and capability,
because replay is blocked by the monotonic `handoff_count` checked at withdraw,
not by refusing a repeat deposit. The registry absorbed the session's
recipient-match check: a deposit that names a recipient (the cross-peer give
routing path) is withdrawable only by that recipient, while a bootstrap
`deposit-gift` names none and the signed give's signature check binds the
recipient at withdraw time. Rows live on the gpa with precise per-row frees: an
arena cannot reclaim a replaced row (memory rule § Vat-scoped gift registry).

A `withdraw-gift` whose gift id names no live deposit: unknown, or already
consumed and awaiting a re-deposit: is not refused. The deposit travels on a
different session than the withdraw, so the withdraw can legitimately arrive
first, and the upstream OCapN suite pins that the exporter answers once the
deposit lands. The bootstrap responder returns
`bootstrap.WithdrawOutcome.awaiting_deposit`, the peer parks the owned receive
(bounded by `SessionLimits.max_pending_withdraws`; overflow is the loud
`PendingWithdrawCapExceeded`, a `resource_exhausted` abort), and every
`Peer.step` retries parked withdraws against the registry. A withdraw whose
deposit never arrives stays parked until teardown; deadlines belong to the
application, above glowcap.

The registry carries no lock. The engine is externally synchronized everywhere;
the prior spinlock made the registry the one self-locking corner. A host that
shares one registry across OS threads owns the locking; a single-threaded host
needs none. The OCapN conformance host
(`conformance/ocapn-conformance/glowcap_peer.zig`) is the latter: one
`driver.core.Host` behind a `driver.Bridge` over a single completion loop, so
every `deposit-gift` / `withdraw-gift` on a sharing peer dispatches on the one
loop thread with no lock. A `deposit-gift` and its matching `withdraw-gift`
still travel on different sessions, so a withdraw parked awaiting a not-yet-seen
deposit is re-driven by the Host pump when the shared registry's deposit count
(`GiftRegistry.deposits`) advances, the single-thread analog of a
thread-per-connection driver's continuous per-session `step`.

## Scope (what this does not decide)

- The handoff wire shapes, the decoded-field signing contract, and the
  cross-peer routing functions are unchanged
  ([ADR-0009](ADR-0009-three-party-handoff-substrate.md) stands for all of that;
  this ADR supersedes only its session-owned gift table).
- Signature verification stays an embedder-boundary concern; the registry
  records the gifter key as opaque provenance and runs no crypto.

## Alternatives Considered

- **Keep the session tables, delete the registry.** Rejected: a per-session
  table cannot serve the spec's cross-session deposit-then-withdraw flow; the
  registry exists because the session shape was insufficient.
- **Reject duplicate deposits (the session's drift).** Rejected: the replay
  guard is the monotonic handoff count, and a gifter re-authorizing the same
  gift id is a legitimate replace; refusing it adds no security and breaks
  re-authorization.
- **Keep the registry's internal spinlock.** Rejected: the engine is externally
  synchronized by contract everywhere else, and a sans-I/O core spinlock is the
  wrong tool for the one threaded host, which may block.

## Consequences

- [`src/ocapn/engine/bootstrap.zig`](../../../src/ocapn/engine/bootstrap.zig)
  owns the registry and the single `resolveForDeposit` / `resolveForWithdraw`
  pair; the non-registry duplicates are gone.
- [`src/ocapn/engine/cross_peer.zig`](../../../src/ocapn/engine/cross_peer.zig)
  deposits and withdraws against `exporter.giftRegistry()`.
- [`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig) keeps
  handoff well-formedness validation only.
- `test/engine/gift_registry_test.zig` pins the authority semantics, including
  the re-deposit-replaces contract; `test/engine/cross_peer_test.zig` pins the
  full withdraw path yielding the re-deposited capability.

## Notes

Supersedes the "Session-owned gift table" decision of
[ADR-0009](ADR-0009-three-party-handoff-substrate.md); every other section of
that ADR (wire shapes, Ed25519 over decoded fields, cross-peer routing, relayed
resolution, gifter-key provenance) remains in force.
