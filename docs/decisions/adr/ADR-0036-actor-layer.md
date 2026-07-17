---
id: ADR-0036
status: accepted
date: 2026-06-07
tags: [actors, vat, layer, sans-io]
decision: "pancake provides a Goblins-shaped actor layer (`src/actors/`) as a new sync, no-I/O layer above the engine. A `Vat` is a turn loop over local actors: typed `spawn`, synchronous near-call (`$`), eventual-send (`<-`) returning a `Vow` with one-shot listeners, and 'become' expressed as mutating an actor's own `self`. A peer-bound vat also binds actors to wire exports and meets the OCapN engine at one location-transparent seam, with a per-turn reply arena. It owns no I/O and adds no CapTP semantics the engine lacks."
supersedes: []
superseded_by: []
---

# ADR-0036 Actor layer

## Context

The vision asks for actors like Goblins so applications are built on pancake the
way they are built on Goblins, with the rest of the vision (Goblins interop, all
bindings) true for them too. The engine already carries the _wire_ half of a vat
(deliver/resolve, promises, exports/imports, listener fan-out), but ADR-0007
explicitly left "actor-model synthesis: running a method and
materializing a value, not implemented; the engine surfaces a deliver event for
the application to dispatch." That gap is an actor layer's job.

Goblins' turn is already a pure function
`(heap, message)` to `(heap', value,
outbound)` driven by a per-turn syscaller, not
an ambient runtime: so an actor layer fits pancake's "sync, no-I/O core, no
hidden runtime" posture without strain.

## Decision

A new layer [`src/actors/`](../../../src/actors/) sits above the engine. Its
core is [`Vat`](../../../src/actors/vat.zig): a turn loop over a heap of local
actors.

- **Actor.** Any type with
  `pub fn handle(self: *@This(), turn: *Turn, msg:
  Message) !model.Argument`
  (and optional `deinit`). Its mutable `self` _is_ its state. Goblins returns a
  fresh behavior via `bcom`; a Zig actor assigns its own fields. Same "become",
  expressed the way Zig already gives you mutable state.
- **`spawn`** is comptime-typed (type-safe construction) and stores actors
  type-erased, so one vat holds heterogeneous actors with no runtime type tax
  beyond one indirect call per turn.
- **`near`** is the synchronous near-call (`$`): run the handler now, return its
  value. **`send`** is the eventual send (`<-`): queue the message, return a
  `Vow`; **`drive`** runs queued turns to quiescence (FIFO, so a send chain
  bottoms out before it returns) and settles each vow: fulfilled with the
  handler's value, or broken on a handler error: firing any one-shot listener
  registered with **`on`**.
- **`Turn`** is the per-turn context (spawn/near/send + the actor's own `Ref`).
  It is an explicit argument, never global: the Zig answer to Goblins's
  `current-syscaller`.

The layer is sync and owns no I/O; `tools/check/arch_check.zig` lists `actors` among
the no-`std.Io` core layers and permits it to import `engine` (for the wire
binding), never the reverse.

## Scope (what this does not decide)

This decision originates the **local** actor model. The remaining open frontier
is far promise pipelining at the actor level, meaning an eventual-send to an
unresolved far vow; the engine owns wire pipelining, and wiring it through the
actor seam is the next slice. Binding actors to the wire, the OCapN/actor seam,
and the per-turn reply lifetime are decided in the section below.

## Alternatives Considered

- **No actor layer; applications dispatch deliver events by hand.** Rejected:
  the vision wants Goblins-grade ergonomics, and every consumer re-implementing
  object tables + promise wiring is the footgun the layer removes.
- **Actors as `*anyopaque` + a registered C-style behavior fn pointer as the
  primary Zig API.** Rejected for the Zig surface: comptime-typed `spawn` is
  safer and idiomatic. (The C ABI projection this left open was later settled
  the other way by [ADR-0039](ADR-0039-binding-actor-idioms.md): bindings
  implement actors natively over the typed peer surface, so no erased-fn-pointer
  C actor ABI is planned.)

## Consequences

New `src/actors/{mod,vat}.zig`, exported from `src/root.zig`; a new arch rule
and core-layer entry in `tools/check/arch_check.zig`. `test/actors/vat_test.zig`
proves near-call dispatch + become, eventual-send promise resolution +
listeners, broken resolution on handler error, and intra-turn spawn/call. No
engine, codec, or session code changed: the layer is purely additive.

## Actor wire hosting, the OCapN seam, and the turn arena

**Wire hosting and the OCapN seam.** A peer-bound `Vat` binds local actors to
engine export positions. Publish an actor as an export, and an inbound
`op:deliver` to that export runs the actor's turn and resolves the answer with
the actor's reply, or breaks it on a handler error. A delivered argument list
led by a symbol reads as a method call (a verb plus its args). The engine and
the actor architecture meet at one seam: a unified `Ref` (a local actor or a far
import) and a `Vow` (local or a wire-answer), routed by the peer-bound vat.
Eventual-send (`<-`) is location-transparent: a local target queues a turn, a
far target leaves as an `op:deliver` over the peer: while near-call (`$`) stays
local-only. The vat rides the engine (it publishes an actor as an export,
allocates an answer for a far send, and fires far promises from inbound
resolutions) and owns no I/O. This closes the "actor-model synthesis not
implemented" note the pipelining work left to the application.

**Turn arena.** An actor handler allocates its reply and any scratch from a
per-turn allocator, `turn.arena`, that the vat owns and reclaims when its next
top-level turn begins. A reply is valid until the vat's next top-level turn,
which is long enough for the vat to fire the local promise's listener or clone
the reply onto the wire, so a handler never frees or leaks its own reply. Nested
near-calls and sends inside one turn share that turn's arena, which resets only
at turn-nesting depth 0. This replaces the earlier "values borrowed for the
turn, no per-call heap reply" caveat.

## Notes

Closes the actor-synthesis gap named in
[ADR-0007](ADR-0007-promise-pipelining-substrate.md). The vat is the same shape
as the in-process conformance ferry loop, generalized to an object heap.
