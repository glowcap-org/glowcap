---
id: ADR-0245
status: accepted
date: 2026-10-14
tags: [codec, syrup, capnp, memory, performance]
decision: "Each codec's encoder walks a borrowed `model.view.Body`. An owned message projects onto that walk through `view.Body.fromOwned`, a decoded frame or a caller's values behind a sequence table reach the wire without being materialized, and the argument writers specialize on their source so an owned tree walks its slices at the cost it had. The Cap'n Proto encoder validates each text where it writes it."
supersedes: []
superseded_by: []
amends: [ADR-0026]
amended_by: []
---

# ADR-0245 Encoders walk borrowed views

## Context

Both encoders took an owned `model.Message`. Anything else that had to
reach the wire was materialized first: a decoded frame re-encoded for a
forwarded handoff or a canonical signing domain was copied into an owned
tree, and a caller's values were lowered into one before the engine
inventoried and encoded them, three walks over the same tree. The decoders
already hand out one borrowed shape, `model.view`, whose sequences lend
their elements from an owned slice, a parsed slab, a word run, or a codec
table alike, so the encoders were the one side of the codec that could not
read it.

The Cap'n Proto encoder also walked the whole tree once before building
to validate its text, so a malformed string was refused before the
builder's first allocation. That walk cost about as much as the encode.

## Decision

The Syrup and Cap'n Proto encoders (`src/ocapn/codec/syrup/encode.zig`,
`src/ocapn/codec/capnp/encode.zig` with `encode_records.zig` and
`encode_arguments.zig`) walk a borrowed body. `encodeBody` and
`encodeBodyForProfile` are the entries for a borrowed body, the codec
registry requires both, and `encodeMessage` and `encodeMessageForProfile`
project an owned message through `view.Body.fromOwned` onto the same walk.

The argument writers take either source, an owned `model.Argument` or a
`view.Argument`, by pointer. The elements of a list, set, tagged value, or
struct are walked through the sequence contract a lazy sequence offers,
`len` and a forward iterator whose `nextRef` lends each element in place,
and an owned slice is wrapped in `view.OwnedSlice` to offer the same. A
borrowed sequence an owner built from its own slice is walked as that
slice. So one writer serves every source, the owned walk pays no
projection, and a sequence whose walk and `len` disagree is refused as
`MalformedView` in every build mode, since the alternative is an
out-of-bounds write.

Signatures are written from whichever shape a codec carried, raw bytes or
Syrup's two halves. A lazy hint list, which only a decoded frame carries,
is projected into scratch at the record that writes it: once for both of
Syrup's render passes when a certificate is canonicalized, once per pass
when a decoded hinted locator is re-encoded, and once on Cap'n Proto.

The Cap'n Proto encoder validates each text where it writes it
(`encode_records.setText`) and reserves a composite list's words with its
tag in one allocation. A malformed string still refuses the encode as
`UnsupportedArgument` and commits nothing, because the builder is the only
effect and it is dropped with the error, but the refusal now follows the
builder's first allocation.

## Scope (what this does not decide)

The engine still encodes an owned tree: lowering, the inventory walk, and
the queue's clone are unchanged. Which callers hand the encoder a borrowed
body, and the Host's sequence backing for its values, are the plan's next
steps.

## Alternatives Considered

- **Comptime-generic encoders over an argument access trait.** Rejected:
  a second encoder shape per source for a saving the owned fast path already
  gives.
- **Keep the owned encoders and add view entries beside them.** Rejected:
  two walks per codec that must agree byte for byte, held together only by
  tests.
- **Keep the separate Cap'n Proto text walk.** Rejected: it doubles the
  encoder's cost to decide which of two errors wins when both the text is
  malformed and the allocator fails, and the refusal commits nothing either
  way.

## Consequences

- `MalformedView` joins both codecs' encode errors.
- The owned path measures within the floor on Syrup, and the Cap'n Proto
  `report` encode drops by about a third (`zig build bench-codec`).
- `test/codec/syrup/encode_view_test.zig` holds the Syrup walk against the
  corpus and the owned walk, and `test/codec/capnp_view_encode_test.zig`
  holds the Cap'n Proto walk, including a body decoded from Syrup.
