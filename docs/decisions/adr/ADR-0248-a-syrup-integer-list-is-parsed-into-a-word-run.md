---
id: ADR-0248
status: superseded
date: 2026-10-14
tags: [codec, syrup, model, performance]
decision: "The Syrup decoder parses a nested list whose elements all fit i64 into little-endian words in the frame head's unused room and backs the `list` view with that run, the backing a Cap'n Proto word run has. Any other list, and one the room cannot hold, takes the general reader."
supersedes: []
superseded_by: [ADR-0250]
amends: []
amended_by: []
---

# ADR-0248 A Syrup integer list is parsed into a word run

[ADR-0250](ADR-0250-struct-views-share-the-frame-head.md) consolidates this decision. It retains the bounded speculative integer-run parse and accounts for its words in the shared byte region.

## Context

ADR-0243 let a Cap'n Proto list of integers reach a reader as a run of
words, so a handler takes it as a slice. A Syrup peer sending the same list
still paid per element. The decoder settled one view for each integer in
the frame head (ADR-0231), validation visited each view, and
`driver.Args.integers` copied the integers into the turn arena. A view
takes as much room as ten integers, so the head ran out of room for long
lists, and a list it could not hold went back to the wire and was parsed
again by every reader.

A Syrup integer is decimal text, so its words have to be computed. The head
already holds room for the frame's views, and the words can live there for
the frame's lifetime with no allocation of their own.

## Decision

`readElements` in `codec/syrup/decode/values.zig` tries a list nested in
the arguments as an integer run before it reads the list's elements as
views. The deliver's own argument list, sets, and tagged values keep their
views. `ValueSlab.beginIntegers` lends the head's unused room, between
the settled views at the bottom and the open parent stack at the top. The
decoder reads each element with the ordinary canonical integer reader and
writes its word. The attempt commits only when every element fits `i64`
and the list closes inside the frame. The run then keeps the bytes its
words fill, and the list's view is backed by the run (`model.view.Args.fromRun`).

A list that holds anything else, is empty, outgrows the room, or passes
`max_collection_elements` commits nothing. The cursor and the room are left
as they were, and the general reader reads the list and decides whether it
is well formed. The attempt reads at most the room's capacity plus the one
element that ends it, and that element lies inside the frame.

A Syrup run is the backing ADR-0243 describes. A reader sees the same
`len`, `at`, and iterator, `driver.Args.integers` lends the words, the
Cap'n Proto encoder copies them in one pass when it forwards the run, and
validation visits no element.

## Alternatives Considered

- **Settle views, then compact them into words.** Rejected: it pays the
  per-element view the run exists to avoid.
- **Scan the list first, then parse it.** Rejected: an integer list, the
  common case, would be read twice. A list that is not a run pays for the
  attempted prefix again when the general reader starts.
- **A separate word buffer per frame.** Rejected: it adds an allocation to
  the inbound frame, whose one allocation is the wire-path floor
  (`.agents/rules/memory.md`).

## Consequences

- ADR-0243 rejected projecting a run into the head's room because the room
  is sized for views. The run now takes a tenth of the room its views took,
  so a list ten times longer fits.
- A Syrup peer and a Cap'n Proto peer reach a handler's
  `driver.Args.integers` the same way, and only a lifted or local delivery,
  a list the room could not hold, or a host that cannot read the words in
  place pays the copy.
- `test/codec/syrup/decode_slab_test.zig` holds the bounds of the lent room
  and a live parent and mixed sibling beside a committed run, and
  `test/codec/syrup/argument_test.zig` holds large integers and malformed
  refusals through the attempt.
