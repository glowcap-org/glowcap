---
id: ADR-0222
status: accepted
date: 2026-10-14
tags: [model, codec, engine, performance]
decision: "A Syrup decoder finds the end of a top-level argument list by parsing every element, so it writes each view into room the frame's owner lends, and the list is view-backed when they fit. The engine lends four views in the frame head, and a longer list stays wire-backed."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0229, ADR-0250]
---

# ADR-0222 An argument list is parsed once, into the frame head

## Context

A borrowed `view.Args` over a Syrup frame keeps the list's byte region and
reads elements off the wire when a consumer walks it. Finding the region
already parses every element, because a Syrup element's length is known
only after it is read. The session validator then walks the list a second
time, and the Vat a third time when it copies the arguments into its turn.
A call round trip profiled at about 2,500 instructions in that reader on
the server and a further 900 on the caller, three walks of two elements.

Cap'n Proto has no such walk: its list is random access, and an element is
read in place when asked for.

## Decision

`model.view.ValueSlab` is room a frame's owner lends the decoder for
the views of one message's top-level argument list. The Syrup decoder's
`readArgumentList` writes each view into that room as the walk reads it.
When the whole list fits, `Args.fromViews` backs the list with the views
and no later reader parses the bytes. When it does not fit, the walk goes
on without writing, the list comes back wire-backed as before, and the slab
is left as it was. The slab bounds memory and never the list. A nested
list stays wire-backed in both cases.

The engine's owned inbound frame lends the room from its head.
`events.Head` holds the parse slot and `head_argument_views` views, four,
in front of the frame's bytes, and `inbound_head_budget_bytes` pins the
head's size. The views borrow the frame and live and die with it, so an
event still costs one allocation. A frame that reaches admission without a
head, and every caller of `decodeBodyForProfile`, decodes with
`ValueSlab.empty` and keeps today's lazy walk. The Cap'n Proto decoder
takes the slab and leaves it untouched.

## Consequences

- A call round trip costs about 1,200 fewer userspace instructions over
  both threads, measured with the benchmarks page's recipe.
- Every owned inbound frame carries 320 more bytes in its head. The cost
  is transient and freed with the frame, and the memory ledger names it.
- `LazySequence` has three backings: owned elements, parsed views, and the
  codec's wire table. The views backing projects nothing and allocates
  nothing.
- A codec module exposes `decodeBodyInto` beside `decodeBodyForProfile`,
  and the registry refuses a codec without it.
- Evidence: `test/codec/syrup/decode_slab_test.zig` holds the fit, the
  overflow, the second list, the nested list, and the malformed element.
  `test/model/view_test.zig` holds the views backing. The engine's lend is
  in `test/engine/parse_once_test.zig`, and the allocation count in
  `test/engine/peer/ownership_test.zig`.
