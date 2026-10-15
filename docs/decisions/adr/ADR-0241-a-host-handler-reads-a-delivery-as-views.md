---
id: ADR-0241
status: accepted
date: 2026-10-14
tags: [actors, driver, memory, performance]
decision: "Actor deliveries borrow argument views for the turn, and Host handlers use one accessor contract over those views or transactionally lifted values when a delivery carries references."
supersedes: [ADR-0237]
superseded_by: []
amends: [ADR-0036]
amended_by: []
---

# ADR-0241 Borrowed delivery arguments for actor and Host handlers

## Context

Decoded arguments already have views that borrow the inbound frame. Copying
that tree into the turn arena before every handler wastes work when the
handler reads only part of it. The handler contract already limits borrows
to the active turn.

A Host also has an authority obligation. Delivered reference and handoff
slots must become canonical opaque identities under one lift transaction.
A failed lift must retire every reference occurrence it did not project.
Eliminating the argument copy must preserve that transaction.

## Decision

Actors use a message shape for each direction. `actors.Message` carries
what a caller sends. `actors.Delivery` carries a verb and borrowed
`model.view.Args` for the active turn. `serve` removes the leading verb
without materializing the remaining arguments. A near call projects its
caller's arguments into the same delivery shape.

Host behaviors receive `driver.Args`, which exposes one set of typed
accessors over frame views or lifted values. Session validation counts
reference and handoff slots in the walk it already performs. That count
travels on the delivery event through the Vat to Host hosting.

When the count is zero, `Hosting.handle` lends the views directly. Leaf
accessors read their backing, collection accessors return nested arguments,
and `values` requests the owned tree when a handler needs one. Integer-run
borrowing follows the representation decisions in ADR-0243 and ADR-0250.

When the count is nonzero or unknown, the Host lifts the complete delivery
before invoking the handler. Capabilities arrive as opaque Host identities
under the existing transaction. Caller-owned and lifted values use the
same accessor contract. The Host's lifting code projects owned values into
views at entry, so one walk implements both input representations.

Arguments borrow the active turn. A handler retaining an argument beyond
that lifetime must copy it. The frame and turn remain live until their
borrowers finish. The C hosted adapter still projects lifted values into
its C argument records.

## Alternatives Considered

- **Make every outgoing message carry views.** This makes callers wrap
  their existing owned slices and couples send construction to receive layout.
- **Keep separate handler APIs for views and values.** Every adapter would
  maintain two representations of the same operation.
- **Lift each capability lazily when its accessor is called.** Unobserved
  occurrences would still need retirement through a second walk or extra
  per-occurrence state.
- **Expose raw wire arguments to Host applications.** Reference arms would
  reveal protocol positions instead of canonical opaque identities.

## Consequences and evidence

A reference-free served delivery can reach a Host handler without copying
its argument tree. Reference-bearing deliveries retain whole-message lift
and failure cleanup. Applications that request `values` pay the owned-tree
cost explicitly.

`src/actors/vat/serve.zig` owns actor delivery,
`src/driver/core/host/hosting.zig` selects the Host backing, and
`src/driver/core/host/args.zig` owns typed accessors.
`test/driver/core_host/view_delivery_test.zig` checks plain and
capability-bearing deliveries and accessors over owned values.
`test/driver/value_views_test.zig` covers projection of application values.

## Related decisions

ADR-0036 owns the actor layer. ADR-0250 owns inbound frame storage.
ADR-0246 owns outbound borrowing, and ADR-0249 owns served reply retention.
