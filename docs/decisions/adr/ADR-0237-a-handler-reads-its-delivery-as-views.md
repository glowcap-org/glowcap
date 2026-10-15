---
id: ADR-0237
status: superseded
date: 2026-10-14
tags: [actors, driver, memory, performance]
decision: "A handler receives a delivery whose arguments are borrowed views. A wire deliver's views read the frame's bytes where they lie, a local call's views project the caller's owned arguments in place, and the Host's lift reads views, so nothing between the decoder and the application copies a value the handler never asked for."
supersedes: []
superseded_by: [ADR-0241]
amends: []
amended_by: []
---

# ADR-0237 A handler reads its delivery as views

[ADR-0241](ADR-0241-a-host-handler-reads-a-delivery-as-views.md) consolidates this decision. It retains actor delivery views and extends the current account to Host accessors and transactional capability lifting.

## Context

The inbound frame's head lends room for a deliver's whole argument tree, and
both decoders fill it in one pass (ADR-0231), so validation already reads
views at every depth. The Vat then undid that work before any handler ran:
`serve` materialized the views into an owned argument slice in the turn arena,
and the Host's lift walked that slice to build the application's values. Two
walks and one full copy of every leaf, on the server, for a tree the handler
reads at most once and often reads partially.

The handler contract already said the arguments are borrowed for the turn.
The copy existed because the handler's message type was the same owned
`Message` a caller builds to send, and a send's arguments are the caller's,
so the two directions shared one shape and the inbound side paid to fit it.

## Decision

The actor layer has two message shapes, one per direction. `actors.Message`
is what a caller sends: a verb and the owned arguments it lends for the call.
`actors.Delivery` is what a handler receives: the verb and `model.view.Args`,
borrowed for the turn. `serve` peels the leading verb symbol with
`model.view.Args.from`, which reslices a slab or slice backing and asks a
codec backing for its tail, so no element is read twice. A near call
projects the sent message into a delivery in place (`Message.delivery`), and
a forward to a far or queued target pays the one copy that leaving the turn
requires (`Delivery.toMessage`).

The Host's lift (`src/driver/core/host/capabilities/lift.zig`) walks views.
Its owned entries (`liftValue`, `ownValue`, `projectValue`,
`discardValueObservation`) project an owned value into a view at the door,
which costs nothing, so there is one walk for both shapes. A wire deliver's
leaf bytes reach the application's values straight from the frame, which
outlives the turn, and the reply is copied onto the wire inside the turn as
before.

## Scope (what this does not decide)

A forward of a view-backed delivery to a far or queued target materializes
it into the turn arena before the queue clones it or the wire takes it. A
queue clone or an encode that reads views is not implemented. The C hosted
behavior still projects the lifted values into C argument records per call.

## Alternatives Considered

- **One `Message` type whose arguments are views in both directions.**
  Rejected: every send site would wrap its owned slice, and the outbound
  engine reads owned trees, so a far send would materialize what the caller
  already owned.
- **An optional box entry that takes views, beside the owned one.** Rejected:
  two handler shapes for one job, and the Vat would still materialize for
  every plain Zig actor.
- **A delivery that carries the whole argument sequence and an offset past
  the verb.** Rejected: the offset leaks the Vat's verb convention into every
  accessor, and a handler's `args` would include the verb.

## Consequences

- A handler's typed accessors (`arg`, `argBytes`, `argString`, `argInt`) read
  views, and a handler that keeps an argument past its turn copies it with
  `Argument.toOwned`.
- `model.view.Args.VTable` carries `tail`, implemented by each codec backing.
- The `report` rows' server instruction counts drop by the materialization
  walk, measured with the callgrind recipe in `bench/README.md`.
