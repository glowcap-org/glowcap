---
id: ADR-0092
status: superseded
date: 2026-07-29
tags: [captp, gc, host, identity]
decision: "An application can deterministically spend a capability handle; ADR-0096 retains that behavior while superseding the session-position/token split with one Host-scoped reference and one release verb."
supersedes: []
superseded_by: [ADR-0096]
amends: []
amended_by: []
---

# ADR-0092 Deterministic Capability Release

> **Superseded by ADR-0096.** `session.release(ref)` remains, but the two C
> release families and their position/token classification do not. Every
> application capability is one opaque Host identity released through
> `pancake_host_ref_release`.

## Problem

[ADR-0063](ADR-0063-finalizer-driven-distributed-gc.md) gave every binding a
finalizer-driven release: opt a session into GC with `withGc()`, and a far
capability from `fetch` gives its import back when the language reclaims the
last handle. That is the right default and it stays. What it does not cover is
an application that already knows, at a definite moment, that it is finished
with a capability.

Two gaps, either of which alone would settle this.

**Opting in does not reach every capability.** ADR-0063 tracks `fetch` results
and says so in its Scope: a capability lifted from a delivered argument, a
send reply, or an `enliven` is deliberately untracked. The case that surfaced
this is exactly that shape. A rooms direct-message line that only sends rides
the directory's session and holds an import it did not fetch, so no amount of
opting in would release it.

**The existing verb is for the other kind of id.** `pancake_host_gc_release`
takes a node-minted token, routes it through the node to whichever connection
hosts it, and refuses a plain wire position. A capability from a delivered
argument carries a wire position. So the C ABI had no entry point for this at
all, and the four bindings reached the one it did have only from inside their
finalizer layers.

There is also a reason of kind rather than of coverage. In a capability system,
"I am no longer holding this authority" is a thing an application means, not a
hint to a collector. Waiting on nondeterministic finalization leaves the
exporter's row reachable for an unbounded time, and an application built on
delegating and withdrawing authority wants the withdrawal to be an act it
performs.

## Decision

Add `pancake_host_session_release_import(session, position, delta)`, and expose
it in every binding as `session.release(ref)`.

**Session-scoped, because an import position is.** The position means something
only on the session holding it, so the session is an argument rather than
something to look up. This is why the verb is `session.release(ref)` and not
`ref.release()`: a binding `Ref` deliberately carries no session, which is what
[ADR-0069](ADR-0069-node-unique-foreign-import-identity.md)'s tokens exist to
paper over for the ids that travel.

**Two verbs, because there are two kinds of id.** A `fetch` result or a redeemed
capability carries a node-unique token; anything else carries a wire position.
`pancake_host_gc_release` keeps the first and refuses the second with
`NotAToken`; the new verb takes the second and refuses the first with
`NotAWirePosition`. Each binding's `release` branches once on the id and calls
the right one, so an application never chooses. Collapsing them into one verb
whose behaviour depends on which band its argument falls in is the shape
[ADR-0091](ADR-0091-reserved-position-bands.md) just removed from routing.

**A released handle is spent, and using it is refused.** This is not tidiness.
Once an import's count reaches zero the partner is free to reuse that position
for a different object, so a handle kept past its release does not name
nothing, it names whatever arrives next. That is the defect class the
[architecture rule](../../../.agents/rules/architecture.md)'s namespace section
is written about. The refusal therefore lives at each language's single
marshalling chokepoint (`lowerArg`, `Ref._wire`, `ref->c`), not in each verb, so
no path can reach the wire around it.

The final decrement also removes resolved sturdyref cache entries for that
position and clears the import row's node-token generation. Every old route
then fails closed, and the Host release path reclaims its map row. Handle
poisoning protects the caller, while clearing those internal lookups protects
the next capability the partner assigns to the same position.

Rust does better than a flag: `release` takes the `Ref` by value, so the
released handle is gone at compile time. `Ref` is `Clone`, so a shared cell
covers the clones the type system cannot, and `Ref::released` reports it.

## Scope (what this does not decide)

- `withGc()` is unchanged and stays off by default. The two are complementary:
  the finalizer path is a safety net for handles an application forgets, this
  is for the ones it knows about.
- No new answer-position release. `op:gc-answers` is already explicit, and
  ADR-0063's reasoning for not wiring a promise-handle finalizer still holds.
- The native Zig tier gains nothing new. It already had the deterministic path
  (`Peer.sendGcExport`), which is why ADR-0063 excluded it from the finalizer
  work; `driver_core.Host.releaseImport` is what the C ABI calls, and a Zig
  consumer may call it too.
- Releasing more than one unit at a time is expressible (`delta`) but no
  binding surfaces it. One handle is one unit, the same rule ADR-0063 uses.

## Consequences

- A second way to give a capability back, which is more public surface. It
  earns it: the finalizer path cannot express "now", and cannot reach a
  capability that did not come from `fetch`.
- An application that releases and then uses gets a loud error where it
  previously got either a stranded row or, after position reuse, a message to
  the wrong object. That is a behaviour change only for code that was already
  wrong.
- `meta-check` holds two things that bit during implementation: an ABI symbol
  reflected into the generated FFI must be wired in every binding or declared
  deferred with a reason, and `pancake_host_gc_release` belongs to each
  binding's `gc` module rather than its session. Both are why this landed in
  four bindings at once and with the machinery beside the finalizer path.
