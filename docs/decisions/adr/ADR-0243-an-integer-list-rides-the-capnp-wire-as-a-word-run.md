---
id: ADR-0243
status: accepted
date: 2026-10-14
tags: [codec, capnp, wire-profile, performance]
decision: "In glowcap's Cap'n Proto profile a non-empty list whose elements are all integers is encoded as a list of eight-byte words, one per element. The decoder backs the `list` view with that run, a reader that can read little-endian words as they lie gets the run as a typed slice, and the metered walk charges the run once as the words it spans."
supersedes: []
superseded_by: []
amends: [ADR-0026]
amended_by: [ADR-0247, ADR-0250]
---

# ADR-0243 An integer list rides the Cap'n Proto wire as a word run

## Context

The Cap'n Proto profile carried every list as a composite list of argument
structs, three words an element, and the decoder projected each element
through the argument union into a view. A list of numbers, the common shape
of application data, paid that per element on both sides: the encoder
reserved and wrote three words, the decoder read a discriminant and a value
and wrote an eighty-byte view, and validation visited each view. On the
`report` row that list was most of the capnp codec's cost above `greet`,
and none of it was the cost of reading the integers.

Cap'n Proto has a list form for exactly this, `List(Int64)`: a list pointer
whose element size is eight bytes and whose content is the elements. The
profile is glowcap's own (ADR-0026), so adding the form changes no outside
contract.

## Decision

The encoder writes a `list` argument with at least one element, all of
them integers, as a run of eight-byte words. Every other list, the empty
list among them, keeps its composite form, so each value has one encoding.
Sets and tagged values keep their composite form too, so the run is a
list's form only.

The decoder follows a `list` argument's pointer once. A composite pointer
takes the walk it took before. An eight-byte pointer is proved to fit the
segment, charged to the traversal budget as the words it spans, and handed
to the view as a run (`model.view.Args.fromRun`), which reads one word per
element in place. An empty run is refused as malformed, because no encoder
writes one. A run under a set is refused as an invalid pointer.

The run is a fourth backing of the lazy sequence beside the owned slice,
the parsed views, and the codec table, and the position lists of the
`gc-*` messages use the same backing. A reader sees the same `len`, `at`,
and iterator. A host that reads little-endian words as they lie (its byte
order is little-endian and the frame is word-shaped, so the run is aligned)
gets the run as a typed slice (`typedRun`), and `driver.Args.integers`
hands a handler that slice with no per-element work. On Syrup, on a lifted
or local delivery, and on a host that cannot read the words in place, the
same accessor copies the integers into the turn arena once per call.

Session validation sees a run as what it is, a list of integers bounded by
the codec, and visits no element of it.

## Alternatives Considered

- **A new `Argument` arm for an integer run.** Rejected: the model would
  gain a second shape for one value, every consumer would switch on it, and
  a Syrup peer and a capnp peer would see different trees.
- **Project the run into slab views.** Rejected: it keeps the per-element
  cost the form exists to remove, and the slab is sized for argument views
  the run does not need.
- **Let the decoder accept an empty run.** Rejected: the empty list would
  have two encodings.
- **Return the words unaligned (`[]align(1) const i64`).** Rejected: a
  handler would carry the alignment into every function it passes the slice
  to. The frame is word-shaped, so the aligned slice is the ordinary case,
  and the copy covers the rest.

## Consequences

- The capnp `report` frame shrinks from 2136 to 1104 bytes, and the bench
  decodes it into lent views in about a quarter of the time
  (`zig build bench-codec`).
- The golden fixtures under `test/codec/capnp_fixtures/` gain
  `op_deliver_integers.bin`, and the malformed suite holds the empty run,
  the over-long run, and the run under a set.
- `driver.Args` carries the turn arena on its values backing, so the copy
  `integers` makes has an owner on every backing.
