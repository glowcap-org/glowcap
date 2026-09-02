---
id: ADR-0102
status: accepted
date: 2026-08-02
tags: [actors, host, driver, scheduling, threads, c-abi]
decision: "A behavior defers its answer onto a resolver vow: a Vat promise minted without a send, settled by an explicit top-level verb. Each driving tier names how a worker's settle call reaches the owning thread — the completion loop and HostRuntime through a bounded mailbox with an fd wake, the byte-fed Host through the embedder's own scheduler, and BlockingSession not at all. Off-thread settles carry plain data only; capability transfer stays on the owning thread."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0113]
---

# ADR-0102 Off-turn settlement

## Status

Accepted. Stage 1 — the resolver vow (`Vat.spawnVow` / `Vat.fulfillVow` /
`Vat.breakVow`) and the behavior-side deferral (`Turn.forwardVow`) — is
implemented and held by `test/actors/resolver_vow_test.zig`. Stage 2 — the
Host-tier atomic deferral (`Host.deferTurn`, the settle verbs, and the hidden
session-less vow row beneath them) and its C exports
— is implemented and held by the resolver scenarios in
`test/driver/core_host/defer_test.zig` and `test/c_abi/host_test.zig`. Stage 3 —
the binding veneers — is implemented with a live proof per binding: the
TypeScript and Python bindings auto-defer a behavior that returns a promise
or awaitable (their smokes' async-worker scenes, on Deno, Bun, and asyncio),
and the Rust and Racket bindings carry the explicit resolver
(`Host::defer_turn` with retryable settle verbs;
`host-defer-turn` with the settle bangs),
each proven by a deferred round-trip with both settle arms. Stage 4 — the
native thread transport — is implemented and held by
`test/driver/off_turn_settle_test.zig`: `driver.SettleMailbox` (fixed slots,
allocation-free posts, an io-aware mutex around the bounded capture, and a
socketpair wake honoring the nudge invariant), polled beside `HostRuntime`'s wires
and armed as an ordinary recv on the completion loop (`Loop.armWake`, which
`Bridge.attachSettleMailbox` wires), with a real worker thread settling a
deferred answer over each tier. The decision is fully implemented.

## Context

One thread drives one Host, and a hosted behavior runs synchronously to the
end of its turn. Work that needs real time inside a turn — disk, a name
lookup, an upstream call, heavy compute — therefore stalls every session
sharing that Host, and at the completion-loop tier that is every connection
the process serves. `docs/boundaries.md` names the consequence and advises
"move blocking work out of the behavior callback," but no mechanism brings
the result back in.

The gap is precise. `Turn.forward` lets a behavior defer its answer onto
another *send*, so every deferral terminates in some behavior's synchronous
turn on the same thread; no chain of forwards can leave it. A local vow
(`actors.Vow.local`) settles only inside `Vat.drive`, when the queued turn
that backs it returns (`settleLocal` asserts as much). There is no promise a
party outside any turn can settle. Spritely Goblins has exactly this
primitive — a promise/resolver pair whose resolver is an ordinary capability —
and its shape is the authority for ours: the read side and the settle
authority are separate values.

Two in-tree precedents shape the thread story. The WebRTC endpoint already
crosses threads safely: entries recorded into bounded staging, applied at
harvest, with a self-pipe nudge whose `WouldBlock` is coalesced success while
every other fault terminalizes the owner (ADR-0089). And the completion loop's
`runUntil` documents today's
only cross-thread wake as "a connect-and-drop against the bound port is
enough" — a workaround describing the seam this decision builds.

This engages the first principles directly: the core stays sync and no-I/O
(the resolver vow is a Vat cell and two verbs; no thread, lock, or fd enters
`actors`), adapters own scheduling (each tier names its own transport for the
settle call), and explicit beats implicit (a behavior states its deferral;
nothing infers it from a returned promise).

## Decision

Add the resolver vow to the actor layer, and keep every thread concern in the
tier that owns threads.

1. **The resolver vow (`actors`, stage 1).** `Vat.spawnVow` mints a local vow
   backed by no queued turn and returns it with a resolver id — separate
   values, the Goblins promise-pair shape, so holding the vow (the read side)
   never confers the settle authority. `Vat.settleVow(resolver, resolution)`
   is a top-level verb like `drive`: refused inside a turn, one-shot (a
   second settle, or a settle of a send-backed vow's id, refuses), and it
   runs listeners under the same drive and settle-arena discipline
   `settleLocal` requires, because a listener may legitimately open a nested
   drive. `Turn.forwardVow(vow)` is the behavior-side deferral: the turn's
   answer settles when the vow settles, through the same forward context
   `Turn.forward` parks. The resolver id is a bare integer in the minting
   Vat's namespace and dies with it.

2. **Host tier and C ABI (stage 2).** `driver_core.Host` atomically reserves a
resolver row and defers the current turn over the same machinery its vows
already use, and the C archive exports that transaction in the
`glowcap_host_*` family with fulfilled and broken settle verbs. These are owning-thread
   verbs like every other export; the Host's one-thread contract does not
   change. A resolver vow belongs to no session, so its row is the
   session-less vow row — the same prerequisite the Racket select-or-dial
   enliven needs, built once here.

3. **The embedder's scheduler carries the hop at the byte-fed tier (stage
   3).** Every binding runtime already owns a thread-safe way onto its loop
   (`call_soon_threadsafe`, a channel to the reactor, a posted task). A
   binding behavior kicks work off, returns after atomic deferral, and the
   completion settles the resolver from the loop. glowcap does not duplicate
   the runtime's cross-thread machinery; each binding ships the recipe and a
   proof in which a behavior answers after real asynchronous work.

4. **The native transport is a bounded mailbox with an fd wake (stage 4).**
   `completion.Loop` and `driver.HostRuntime` — the two native tiers that own a
   wait — gain a settle mailbox: entries recorded under a lock from any
   thread using that thread's `std.Io`, applied at the top of the owning
   thread's iteration, woken by a socketpair fd whose write follows the
   ADR-0089 nudge contract. A failed wake rolls back the uncommitted post and
   terminalizes the mailbox owner without abandoning rows admitted earlier.
   The mailbox is bounded in rows and bytes; a full mailbox refuses the
   worker's settle loudly rather than blocking the loop or growing without
   bound. This replaces the connect-and-drop wake as the sanctioned
   cross-thread entry.

5. **Off-thread settles carry plain data only.** A settle recorded from
   another thread clones a capability-free resolution (strings, numbers,
   structure over them) into the mailbox under its io-aware mutex. A resolution
   that introduces a capability must be performed on the owning thread, where
   every existing verb already is. Authority never crosses threads inside
   glowcap.

`BlockingSession` stays out: it parks in a read with nothing to wake, and
its contract is one connection on one fiber. An application that needs
off-turn completion uses `HostRuntime` or the loop; `docs/boundaries.md` says
so beside the advice this mechanism completes.

## Scope (what this does not decide)

- No thread pool, executor, or worker API. The application owns its threads;
  glowcap owns only the re-entry seam.
- No cross-thread capability transfer, and no relaxation of the one-thread
  Host contract anywhere else.
- No preemption or multi-Vat sharding; a slow turn still stalls its Host,
  and the answer to that remains separate Hosts.
- No wire semantics. A resolver vow is local machinery; nothing new is
  encoded, negotiated, or visible to a partner.

## Consequences

- The boundaries advice becomes a mechanism, and the loop gains its first
  sanctioned cross-thread entry, which `runUntil`'s stopper can share.
- Binding behaviors stop being forced into reply-capability protocol
  contortions for ordinary asynchronous work.
- The session-less vow row lands once and unblocks the Racket host-level
  enliven veneer recorded in `docs/boundaries.md`.
- A new refusal class exists (settle of a settled or send-backed vow, settle
  from inside a turn, a full mailbox), each typed and tested; nothing
  silent. Spawning the pair inside a turn is legal — that is the primary
  use: a behavior mints, forwards, and hands the resolver to its worker.
