---
id: ADR-0242
status: superseded
date: 2026-10-14
tags: [codec, performance, resilience]
decision: "The Cap'n Proto decoder walks an inbound frame once: the walk that parses the argument tree into the frame head's views is the walk metered against the traversal budget, and a subtree it leaves wire-backed is descended under the same budget before its backing escapes."
supersedes: []
superseded_by: [ADR-0250]
amends: []
amended_by: []
---

# ADR-0242 The Cap'n Proto decoder's metered walk is its only walk

[ADR-0250](ADR-0250-struct-views-share-the-frame-head.md) consolidates this decision. It retains the single metered traversal and budgeted fallback, and includes cached struct entries and integer runs.

## Context

A Cap'n Proto frame's pointers may alias, so the decoder meters every walk
over a frame against a per-frame word budget, and an aliasing graph that
would amplify a walk is refused in bounded time. ADR-0231 made the decoder
parse a deliver's argument tree once into the views the frame head lends.
The decoder still walked the tree twice: an eager charge pass projected every
argument against the metered reader and threw the projection away, and the
fill pass projected every argument again, unmetered, into the views. On the
`report` row that second projection cost the server about six thousand
instructions a round trip, and every string in a list was checked for
well-formed UTF-8 twice.

## Decision

`decodeBodyInto` runs one walk. The body projectors in
`codec/capnp/decode.zig` read through a reader metered with the frame's
traversal budget, each composite element costs one budget word over the
words it reads, and `values.neutralArgs` parses each list it meets into the
slab when the slab has room. The observer a projector passes for locator
hint lists (`values.chargeHintList`) is what marks the metered walk: a lazy
re-walk of a wire-backed sequence passes none, and never descends. A subtree
the metered walk leaves wire-backed is descended under the budget before its
backing escapes: a list the slab cannot hold, a struct's values
(`values.neutralStructBacking`), and a locator's hint list. The nesting
bound is held where a collection is entered, as the Syrup decoder holds it.
No view carries the budget pointer, so the budget dies with the walk.

## Scope (what this does not decide)

A struct's entries still have no room of their own and stay wire-backed, as
ADR-0231 leaves them. The budget's size and the frame's room are unchanged.

## Alternatives Considered

- **Keep the charge pass and make the fill pass cheaper**: the fill pass
  already did the minimum per element. The waste was the second walk.
- **Meter only the fill and trust the slab to hold every list**: a list past
  the room would escape as a wire-backed sequence whose later walks no budget
  had bounded, which reopens the amplification the budget exists to close.
- **A separate walk flag beside the hint observer**: the observer already
  exists on every projector and already means the metered walk at the one
  site that enumerates hints. A second flag would be a second way to say it.

## Consequences

- The Cap'n Proto `report` server fell from about 45,900 to 39,900
  instructions a round trip under the callgrind recipe in `bench/README.md`,
  with the Syrup rows and both `greet` rows unchanged within the floor. Under
  `bench-codec`, decoding the `report` frame into lent views fell from 912 ns
  to 570 ns.
- Evidence: `test/codec/capnp_malformed_test.zig` refuses the aliasing
  composite DAG through both `decodeBody` and `decodeBodyInto` with room
  lent, and refuses an aliasing hint list and an over-deep frame.
  `test/codec/capnp_test.zig` pins the claimed tree and the backed fallback.
  `test/codec/fuzz_test.zig` drives the whole decode surface.

## Notes

ADR-0231 owns the frame head's room. The threat model's Cap'n Proto row
names the budget this walk spends.
