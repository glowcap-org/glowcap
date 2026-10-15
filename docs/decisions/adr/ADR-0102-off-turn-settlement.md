---
id: ADR-0102
status: accepted
date: 2026-08-02
tags: [actors, host, driver, scheduling, threads, c-abi]
decision: "A behavior defers its answer onto a resolver vow: a Vat promise minted without a send, settled by an explicit top-level verb. Each driving tier names how a worker's settle call reaches the owning thread: the completion loop and HostRuntime through a bounded mailbox with an fd wake, the byte-fed Host through the embedder's own scheduler, and BlockingSession not at all. Off-thread settles carry plain data only. Capability transfer stays on the owning thread."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0113, ADR-0182]
---

# ADR-0102 Off-turn settlement

## Status

Accepted and fully implemented.

- Stage 1, the resolver vow (`Vat.spawnVow`, `Vat.fulfillVow`,
  `Vat.breakVow`) and `Turn.forwardVow`: `test/actors/resolver_vow_test.zig`.
- Stage 2, Host-tier deferral (`Host.deferTurn`, the settle verbs, the
  session-less vow row) and its C exports: `test/driver/core_host/defer_test.zig`
  and `test/c_abi/host/callback_test.zig`.
- Stage 3, the bindings: TypeScript and Python defer a behavior that returns a
  promise or awaitable. Rust (`Host::defer_turn`) and Racket
  (`host-defer-turn`) use the explicit resolver. Each binding's smoke settles
  both ways.
- Stage 4, the thread transport (`driver.SettleMailbox`, `Loop.armWake`,
  `Bridge.attachSettleMailbox`): `test/driver/off_turn_settle_test.zig`, with a
  real worker thread on each tier.

## Context

One thread drives one Host, and a hosted behavior runs synchronously to the
end of its turn. Work that needs real time inside a turn (disk, a name
lookup, an upstream call, heavy compute) therefore stalls every session
sharing that Host, and at the completion-loop tier that is every connection
the process serves. `docs/boundaries.md` names the consequence and advises
"move blocking work out of the behavior callback," but no mechanism brings
the result back in.

`Turn.forward` lets a behavior defer its answer onto another send, so every
deferral terminates in some behavior's synchronous turn on the same thread. No
chain of forwards can leave it. A local vow (`actors.Vow.local`) settles only
inside `Vat.drive`, when the queued turn that backs it returns (`settleLocal`
asserts as much). No promise exists that a party outside any turn can settle.
Spritely Goblins has this primitive, a promise/resolver pair whose resolver is
an ordinary capability, and its shape is the authority for ours: the read side
and the settle authority are separate values.

Two in-tree precedents shape the thread story. The WebRTC endpoint crosses
threads safely: entries are recorded into bounded staging and applied at
harvest, with a self-pipe nudge whose `WouldBlock` is coalesced success while
every other fault terminalizes the owner (ADR-0089). The completion loop's
`runUntil` documents the only cross-thread wake as "a connect-and-drop against
the bound port is enough".

## Decision

The actor layer has a resolver vow, and every thread concern lives in the tier
that owns threads.

1. **The resolver vow (`actors`, stage 1).** `Vat.spawnVow` mints a local vow
   backed by no queued turn and returns it with a resolver id, as separate
   values (the Goblins promise-pair shape), so holding the vow (the read side)
   never confers the settle authority. `Vat.settleVow(resolver, resolution)` is
   a top-level verb like `drive`: refused inside a turn, one-shot (a second
   settle, or a settle of a send-backed vow's id, refuses), and it runs
   listeners under the same drive and settle-arena discipline `settleLocal`
   requires, because a listener may open a nested drive. `Turn.forwardVow(vow)`
   is the behavior-side deferral: the turn's answer settles when the vow
   settles, through the same forward context `Turn.forward` parks. The resolver
   id is a bare integer in the minting Vat's namespace and dies with it.

2. **Host tier and C ABI (stage 2).** `driver_core.Host` atomically reserves a
   resolver row and defers the current turn over the machinery its vows use,
   and the C archive exports that transaction in the `glowcap_host_*` family
   with fulfilled and broken settle verbs. These are owning-thread verbs like
   every other export, under the Host's one-thread contract. A resolver vow
   belongs to no session, so its row is the session-less vow row, the same
   prerequisite the Racket select-or-dial enliven needs.

3. **The embedder's scheduler carries the hop at the byte-fed tier (stage 3).**
   Every binding runtime already owns a thread-safe way onto its loop
   (`call_soon_threadsafe`, a channel to the reactor, a posted task). A binding
   behavior kicks work off, returns after atomic deferral, and the completion
   settles the resolver from the loop. glowcap does not duplicate the runtime's
   cross-thread machinery. Each binding ships the recipe and a proof in which a
   behavior answers after real asynchronous work.

4. **The native transport is a bounded mailbox with an fd wake (stage 4).**
   `completion.Loop` and `driver.HostRuntime`, the two native tiers that own a
   wait, have a settle mailbox: entries recorded under a lock from any
   thread using that thread's `std.Io`, applied at the top of the owning
   thread's iteration, woken by a socketpair fd whose write follows the
   ADR-0089 nudge contract. A failed wake rolls back the uncommitted post and
   terminalizes the mailbox owner without abandoning rows admitted earlier.
   The mailbox is bounded in rows and bytes. A full mailbox refuses the
   worker's settle loudly. It never blocks the loop or grows without bound.
   This is the sanctioned cross-thread entry in place of the connect-and-drop
   wake.

5. **Off-thread settles carry plain data only.** A settle recorded from
   another thread clones a capability-free resolution (strings, numbers,
   structure over them) into the mailbox under its io-aware mutex. A resolution
   that introduces a capability must be performed on the owning thread, where
   every existing verb already is. Authority never crosses threads inside
   glowcap.

`BlockingSession` stays out: it parks in a read with nothing to wake, and
its contract is one connection on one fiber. An application that needs
off-turn completion uses `HostRuntime` or the loop. `docs/boundaries.md` says
so beside the advice this mechanism completes.

## Scope (what this does not decide)

- No thread pool, executor, or worker API. The application owns its threads.
  glowcap owns only the re-entry seam.
- No cross-thread capability transfer, and no relaxation of the one-thread
  Host contract anywhere else.
- No preemption or multi-Vat sharding. A slow turn still stalls its Host,
  and the answer to that remains separate Hosts.
- No wire semantics. A resolver vow is local machinery. Nothing new is
  encoded, negotiated, or visible to a partner.

## Consequences

- The boundaries advice "move blocking work out of the behavior callback" has a
  mechanism, and the loop has a sanctioned cross-thread entry that `runUntil`'s
  stopper can share.
- Binding behaviors need no reply-capability protocol contortions for ordinary
  asynchronous work.
- The session-less vow row unblocks the Racket host-level enliven veneer
  recorded in `docs/boundaries.md`.
- The refusals (settle of a settled or send-backed vow, settle from inside a
  turn, a full mailbox) are typed and tested. Spawning the pair inside a turn
  is legal and is the primary use: a behavior mints, forwards, and hands the
  resolver to its worker.

Queued local eventual calls support the same answer deferral as wire calls. A
synchronous near call refuses deferral, and the Host refuses deferring a tell
because it has no answer. `Turn.origin` carries this distinction.

### Owning-thread application values

The plain-data resolver remains the worker/mailbox contract. The Host also
exposes `resolverFulfillValue`: it uses the deferred row's original caller
session to lower an owning `Value` through the existing transactional capability
projection. Stale and cross-session capabilities refuse the whole value,
including nested containers, without consuming the resolver or retaining new
projections. Successful settlement consumes the resolver once. This path borrows
leaf data. The caller supplies the arena for temporary lowering containers and
rollback receipts. The C adapter gives those receipts an independent arena so
listener reentry cannot overwrite them through argument scratch.

The C ABI exports `glowcap_host_resolver_fulfill_value`. Rust exposes
`Resolver::fulfill_value`. Rust's `fulfill` and the other bindings' resolver
veneers are capability-free. A cross-session gift still requires ordinary
send/handoff machinery. The owning-thread value method leaves the mailbox and
one-thread Host contract unchanged. Core tests cover local and wire callers,
projection rollback after a nested foreign capability, one-shot settlement and
calling a returned actor after its application root is released. The native
Rooms archive exercises the C/Rust path with asynchronous digest lookup followed
by calls to the returned blob reader.
