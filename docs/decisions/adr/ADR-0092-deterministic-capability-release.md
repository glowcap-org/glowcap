---
id: ADR-0092
status: superseded
date: 2026-07-29
tags: [captp, gc, host, identity]
decision: "An application can deterministically spend a capability handle. ADR-0096 retains that behavior while superseding the session-position/token split with one Host-scoped reference and one release verb."
supersedes: []
superseded_by: [ADR-0096]
amends: []
amended_by: []
---

# ADR-0092 Deterministic Capability Release

> **Superseded by ADR-0096.** `session.release(ref)` remains, but the two C
> release families and their position/token classification do not. Every
> application capability is one opaque Host identity released through
> `glowcap_host_ref_release`.

## Problem

[ADR-0063](ADR-0063-finalizer-driven-distributed-gc.md) gave every binding a
finalizer-driven release: opt a session into GC with `withGc()`, and a far
capability from `fetch` gives its import back when the language reclaims the
last handle. That is the right default. It does not cover an application that knows, at a
definite moment, that it is finished with a capability.

**Opting in did not reach every capability.** ADR-0063 originally tracked
`fetch` results, and capabilities lifted from delivered arguments, send replies
and `enliven` were untracked. The current ADR-0063 contract covers all those
projected occurrences, including cached enliven results. A rooms direct-message
line that only sends rides the directory's session and holds an import it did
not fetch, which opting in did not release.

**The existing verb is for the other kind of id.** `glowcap_host_gc_release`
takes a node-minted token, routes it through the node to whichever connection
hosts it, and refuses a plain wire position. A capability from a delivered
argument carries a wire position, so the C ABI had no entry point for it, and
the four bindings reached the existing one only from inside their finalizer
layers.

In a capability system, "I am no longer holding this authority" is something an
application means, not a hint to a collector. Nondeterministic finalization
leaves the exporter's row reachable for an unbounded time, and an application
that delegates and withdraws authority wants the withdrawal to be an act it
performs.

## Decision

Add `glowcap_host_session_release_import(session, position, delta)`, and expose
it in every binding as `session.release(ref)`.

**Session-scoped, because an import position is.** The position means something
only on the session holding it, so the session is an argument. The verb is
`session.release(ref)` and not `ref.release()` because a binding `Ref` carries
no session, which [ADR-0069](ADR-0069-node-unique-foreign-import-identity.md)'s
tokens cover for the ids that travel.

**Two verbs, because there are two kinds of id.** A `fetch` result or a redeemed
capability carries a node-unique token. Anything else carries a wire position.
`glowcap_host_gc_release` keeps the first and refuses the second with
`NotAToken`. The new verb takes the second and refuses the first with
`NotAWirePosition`. Each binding's `release` branches once on the id and calls
the right one, so an application never chooses. One verb whose behavior depends
on which band its argument falls in is the shape
[ADR-0091](ADR-0091-reserved-position-bands.md) removes from routing.

**A released handle is spent, and using it is refused.** Once an import's count
reaches zero the partner may reuse that position for a different object, so a
handle kept past its release names whatever arrives next. The
[architecture rule](../../../.agents/rules/architecture.md)'s namespace section
covers this defect class. The refusal lives at each language's single
marshalling chokepoint (`lowerArg`, `Ref._wire`, `ref->c`), not in each verb, so
no path reaches the wire around it.

The final decrement also removes resolved sturdyref cache entries for that
position and clears the import row's node-token generation. Every old route
then fails closed, and the Host release path reclaims its map row. Handle
poisoning protects the caller, while clearing those internal lookups protects
the next capability the partner assigns to the same position.

In Rust, `release` takes the `Ref` by value, so the released handle is gone at
compile time. `Ref` is `Clone`, so a shared cell covers the clones the type
system cannot, and `Ref::released` reports it.

## Scope (what this does not decide)

- `withGc()` stays off by default. The two are complementary: the finalizer path
  is a safety net for handles an application forgets, and this verb is for the
  ones it knows about.
- No new answer-position release. `op:gc-answers` is already explicit, and
  ADR-0063's reasoning for not wiring a promise-handle finalizer still holds.
- The native Zig tier has the deterministic path (`Peer.sendGcExport`), which is
  why ADR-0063 excluded it from the finalizer work.
  `driver_core.Host.releaseImport` is what the C ABI calls, and a Zig consumer
  may call it too.
- Releasing more than one unit at a time is expressible (`delta`) but no
  binding surfaces it. One handle is one unit, the same rule ADR-0063 uses.

## Consequences

- A second way to give a capability back adds public surface. The finalizer
  path cannot express "now", and cannot reach a capability that did not come
  from `fetch`.
- An application that releases and then uses gets a loud error, where it would
  otherwise get a stranded row or, after position reuse, a message to the wrong
  object.
- `source-check` holds two rules: an ABI symbol reflected into the generated FFI
  must be wired in every binding or declared deferred with a reason, and
  `glowcap_host_gc_release` belongs to each binding's `gc` module rather than
  its session.
