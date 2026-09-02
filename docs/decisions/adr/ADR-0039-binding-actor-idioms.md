---
id: ADR-0039
status: accepted
date: 2026-06-07
tags: [actors, bindings, racket, goblins, seam]
decision: "Each binding realizes the actor seam (local | far refs, near-call vs eventual-send, promises) in its own native idiom over the typed peer C ABI: no foreign actor callbacks, no wrapped C vat. The Racket binding is Goblins-faithful: `(define (^name bcom arg …) …)` constructors, `methods`, `spawn`, `$` (near), `<-`/`<-np` (eventual), `on` (with `#:catch`/`#:finally`/`#:promise?`), `bcom` as an injected become-token installed after the turn, and a `current-vat` parameter entered with `with-vat`. The other bindings follow the same seam in their own idiom."
supersedes: []
superseded_by: []
---

# ADR-0039 Binding actor idioms

## Context

Actors are why glowcap exists: the goal is that building a distributed (OCapN)
system in Zig _or any binding_ feels native enough to be the obvious choice in
that language. So the actor layer must live in each binding's own idiom, not as
a wrapped C vat invoked through foreign callbacks. The glowcap-Zig actor seam
(ADR-0036: a unified `Ref` local|far, location-transparent `<-`, near-only `$`,
promises spanning local and wire) is the model; each binding mirrors it
in-language over the existing typed peer C ABI (`register_export`, the typed
deliver poll, `send_resolve`): exactly the way the async layers use native
sockets. No new C ABI is needed.

The Racket binding is the closest target and the proof: it should feel like
Spritely Goblins, because a Racket distributed-systems programmer already
reaches for Goblins, and glowcap-on-Racket should be at home next to it.

## Decision

The Racket actor layer
([`bindings/racket/glowcap.rkt`](../../../bindings/racket/glowcap.rkt)) is
Goblins-faithful:

- An actor is a **constructor** `(define (^name bcom arg …) <behavior>)` the vat
  calls once at spawn; the behavior it returns handles calls, and state lives in
  the constructor's closure.
- **`bcom`** is injected into the constructor (a closure over the actor's
  behavior cell), not a forgeable global. A behavior "becomes" by _returning_
  `(bcom
  new-behavior [result])`; the vat installs the new behavior **after**
  the turn returns, so a mid-turn become cannot tear out the call in flight,
  matching Goblins' return-your-successor semantics.
- **`methods`** dispatches a behavior on a leading method symbol; **`spawn`**
  returns a local `actor-ref`; **`$`** is the synchronous near-call (local only
  a far ref errors, as Goblins forbids); **`<-`** / **`<-np`** are the
  eventual sends returning a vow; **`on`** registers
  fulfilled/`#:catch`/`#:finally` handlers with `#:promise?` chaining;
  **`drive`** runs queued local turns.
- The seam: a reference is a local `actor-ref` or the peer's `far-ref`. `<-` to
  a far ref marshals the leading method symbol to an OCapN `(sym …)` and sends
  an `op:deliver` over the peer; `(bind-export! v actor export-id)` exports a local
  actor; `(vat-serve! v event)` runs an inbound deliver and resolves the answer,
  or fires a far promise on an inbound resolution. A `current-vat` parameter
  (entered via `with-vat`) makes `spawn`/`$`/`<-` work inside a turn, the way
  Goblins binds its current syscaller.

The Rust, Python, and Deno bindings present the same seam: local|far refs,
near-call vs eventual-send, promises: in their own idiom (a Rust closure/trait,
a Python callable, a Deno callback). All four bindings realize it; the
per-binding parity is detailed below.

## Scope (what this does not decide)

`define-actor` sugar is optional; the stable canonical form is the plain
constructor + `spawn`. Far promise pipelining (eventual-send to an unresolved
far vow) is not yet wired.

## Alternatives Considered

- **A C actor ABI with foreign-callback behaviors.** Rejected: it would make a
  Racket actor a C trampoline, not a Racket procedure: the opposite of native
  feel, and the reentrant-callback FFI is gratuitous when the typed peer surface
  already suffices.
- **One shared actor implementation behind the C ABI.** Rejected: the value is
  the _native idiom_ in each language; a shared core would force one language's
  shape on all.

## Consequences

`bindings/racket/glowcap.rkt` gains the Goblins-faithful actor section
(replacing the earlier basic `vat`/`host`); `bindings/racket/zig-smoke.rkt`
drives a local counter (constructor + `methods` + `bcom`, `spawn`, `$`, `<-` +
`on` + `drive`) and a hosted-actor deliver/resolve. `bindings/README.md`
documents the per-binding actor idioms. No C ABI or Zig change.

## All-binding seam parity

All four bindings realize the full local-or-far actor seam, each in its own
idiom over the typed peer C ABI, and each proves a far-send round-trip in its
dogfood smoke. A binding `Vat` holds local actors, routes an eventual-send to a
far reference over the wire, publishes a local actor on a peer export, and
serves an inbound deliver and resolve, folding the separate `Host` into the
peer-bound vat the same way the Zig seam does. Rust, Python, and Deno are
brought to the model the Racket binding set, so `<-` is location-transparent in
every binding.

## Notes

Realizes the seam of [ADR-0036](ADR-0036-actor-layer.md) in the bindings.
Goblins (Apache-2.0, vendored under `conformance/spritely-goblins/`) is the
idiom reference; glowcap's wire is the transport.
