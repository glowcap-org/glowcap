---
id: ADR-0246
status: accepted
date: 2026-10-14
tags: [engine, session, actors, driver, memory, performance]
decision: "A deliver whose arguments carry no reference leaves as the caller lends it. The session certifies the borrowed tree with the rules the owned inventory applies, admission charges, encodes, and queues it through the one door an owned deliver takes, the Port splices the verb into a stack spine of views, and the Host's values back a view sequence. A send that names a capability keeps the owned path."
supersedes: []
superseded_by: []
amends: [ADR-0234, ADR-0236]
amended_by: []
---

# ADR-0246 A deliver of values leaves as the caller lends it

## Context

A deliver leaves the engine as its frame at admission (ADR-0236), and the
encoders read a borrowed body (ADR-0245). Between them the caller still
built an owned tree for the engine to read once: the Host lowered every
value into `model.Argument` storage, the session walked that tree to
inventory it (ADR-0234), and the encoder walked it again. On the `report`
call that was three walks over sixty-four integers and eight strings, about
a third of the caller's cost over `greet`, for a tree the session never
acted on, because it held no reference.

The owned path exists for what the session does act on. Lowering turns a
capability into a wire reference, the inventory lists every slot that holds
a reference, handoff, or set, and shortening rewrites those slots in place.
A tree with no such slot gives every one of those passes nothing to do.

## Decision

A deliver's arguments may be lent as views, freight: a tree of values the
session certifies and the encoder reads, and that nothing rewrites or
retains.

- **The session certifies freight** (`Session.certifyFreight`,
  `src/ocapn/session/validate/freight.zig`). One walk applies the rules the
  inventory applies to an owned tree: the nesting bound, set element
  uniqueness through the borrowed fold, and struct key uniqueness, and it
  refuses a reference or handoff anywhere in the tree as
  `MalformedMessage`, since a tree that names one needs lowering,
  shortening, and a retain. The walk also measures the tree as the owned
  model measures it, so the producer check charges freight before its
  frame exists.
- **Admission has one door** (`outbound/encoded.zig`'s `admit`). Freight
  rides beside the owned envelope: the envelope carries the target, the
  answer, and the resolver, the inventory covers those, and the frame is
  encoded from a body whose arguments are the lent views. Exports,
  resolver, answer, reservation, and retraction are the owned path's,
  unchanged. `Peer.sendFreight` is the entry.
- **The Port decides how a delivery leaves** (`Port.sendDelivery`,
  `Port.tellDelivery`). Arguments behind an owned slice go as that message.
  A far delivery whose views session validation counted no reference in
  leaves as freight, the verb spliced ahead of the views in the same
  stack-backed spine an owned send uses, and a sequence whose walk and
  length disagree is refused before the peer sees it. Any other views are
  materialized once. `Turn.sendDelivery` and `Turn.tellDelivery` hand a far
  delivery to the Port as the handler holds it, which is how a forwarded
  wire deliver with no reference now leaves without a copy.
- **The Host's values back a view sequence**
  (`src/driver/core/value_views.zig`). A far send of values with no
  capability lends them through that backing and lowers nothing. A
  capability has no projection without a session, so the Host scans the
  tree once and a tree that carries one takes the owned path.

## Scope (what this does not decide)

A local target and a capability-bearing send keep the owned path.
[ADR-0247](ADR-0247-a-caller-lends-a-typed-integer-run.md) owns the Host's
typed integer run and its measured projection cost.

## Alternatives Considered

- **Encoders that read `driver.Value` directly.** Rejected: the codec would
  learn a driver type, and the session would certify a tree it cannot read.
- **Projecting the values into a view slab.** Rejected: it allocates and
  still walks the tree once to fill the slab.
- **Certifying inside the encoder.** Rejected: the codec would hold the
  session's nesting and uniqueness authority.
- **Sharing certification with the codec's size pass.** Rejected after a
  measured prototype. A session-owned visitor saved caller instructions on
  Syrup and added them on Cap'n Proto. Paired ReleaseFast runs did not show
  a clear application-message gain from the added visitor and measurement
  APIs. Certification keeps its own walk.
- **A capability arm on `model.Argument`.** Rejected: the model would carry
  a Host identity no codec can render.

## Consequences

- The caller builds no owned tree for a capability-free far send. The
  session still certifies its views and the encoder still reads them.
  ADR-0247 records the cost of projecting individual values and the gain
  from lending integer samples as a typed run.
- `test/session/freight_test.zig` holds the certifier to the owned rules,
  `test/engine/peer/freight_send_test.zig` holds admission, refusal, and
  retry, `test/actors/freight_send_test.zig` holds the Port's allocation
  budget and the length check, and `test/driver/value_views_test.zig` holds
  the projection.
