---
id: ADR-0046
status: accepted
date: 2026-06-11
tags: [model, codec, syrup, capnp, conformance, data-model]
decision: "The OCapN Struct passable is modeled as an ordered-on-the-wire, equality-unordered sequence of (String key, Value) entries (model.StructEntry), carried by both codecs (Syrup as a dict {} and Cap'n Proto as a composite list of entry structs) with String-only keys, duplicate keys refused at decode, canonical key order on encode, and order-independent structural equality. Undefined is already the existing .void arm (Goblins marshals the unspecified value as the <void> record); Null stays unmodeled because Goblins has no Null marshalling and the upstream encoding is unsettled."
supersedes: []
superseded_by: []
---

# ADR-0046 Struct passable

## Context

The OCapN passable data model has a Struct type: an unordered collection of
(key, value) pairs where each key is a String (Model.md § Struct). glowcap
modeled every other passable but refused Struct fail-closed, and a test pinned
that refusal. A complete, canonical OCapN data model needs Struct, and it is the
container the beachhead features pass around, so it is a cross-cutting
foundation: it touches the model type, both codecs, structural equality, and
conformance.

The neighboring atoms forced an evidence question, and the conformance oracle
answered it. Goblins is the wire authority. Its CapTP marshalling
(`conformance/spritely-goblins/upstream/goblins/ocapn/captp.rkt`) marshals a
hash straight to a Syrup dictionary, marshals the unspecified value `(void)` as
the `<void>` record, and has **no** Null case at all. So Undefined is already
glowcap's existing `.void` arm: the `<void>` record both peers already speak,
and Null has no settled wire encoding to implement. Inventing one would be
folklore that cannot interop, which is the opposite of canonical.
Arbitrary-precision Integer is a real, settled gap (Goblins uses Racket
bignums), but it is a scalar extension orthogonal to Struct and is tracked
separately.

This engages the First Principles that protocol evidence beats implementation
folklore, that the session owns authority while codecs parse and render, and
that a copy on the wire path is forbidden, named, or measured.

## Decision

Struct is one new `Argument` arm in both the owned model and the borrowed view.

The owned model gains `model.StructEntry { key: []const u8, value: Argument }`
and the arm `Argument.@"struct": []const StructEntry`. The key is an OCapN
String. The borrowed view gains `view.StructEntry` and `view.StructEntries`, a
`LazySequence(model.StructEntry, view.StructEntry)`, so a struct stays a
borrowed, single-cursor walk over the wire region until `toOwned` materializes
it: the same zero-allocation projection list and set already use. Modeling
entries as a sequence (rather than two parallel key/value lists) is what makes
the single-cursor lazy view fit both codecs.

Both codecs carry it. Syrup encodes a struct as a dictionary `{ key value … }`
and decodes `{` back to the arm; keys are written as Syrup strings, and entries
are emitted in canonical order: sorted by the fully-encoded key, matching the
upstream Syrup encoder (`conformance/syrup/upstream/impls/python/syrup.py`).
Cap'n Proto adds `ArgKind.@"struct"` and carries it as a composite list of entry
structs, each a two-pointer struct holding the key text and the value Argument,
mirroring how `.tagged` is carried.

The typed C waist carries the same entry sequence without adding a second
recursive ABI type: `GLOWCAP_ARG_STRUCT` uses `GlowcapArgument.items` as an
even-length alternating sequence of `_STRING` keys and values. The shared
marshaller enforces the even count, String-only keys, and uniqueness once;
Rust, TypeScript, Python, and Racket expose only idiomatic wrappers over that
one contract.

Decode is fail-closed on the spec's key rules. A non-String key is refused, and
a duplicate key is refused, at the codec boundary where bytes are parsed,
projected as the existing `UnsupportedArgument` / `MalformedFrame` refusals.
Equality is order-independent: two structs are Equal when they have the same
length and every key in one is present in the other with an equal value
(`model.equality.structsEqualDepth`), the keyed analogue of the order-agnostic
set equality. Canonical encode order plus order-independent equality together
give the round-trip the spec requires: a struct may validly round-trip into a
different key order and still be Equal.

## Scope (what this does not decide)

- **Null stays unmodeled.** Goblins has no Null marshalling and the upstream
  encoding is unsettled (Model.md marks the Guile/Python mappings "tentative" /
  "imported"). glowcap does not invent a Null arm; unknown Syrup records project
  as `Tagged` (break/exception leniency), not as a dedicated Null refuse.
- **Undefined is not a new arm.** It is the existing `.void` arm, the `<void>`
  record Goblins uses for the unspecified value. This ADR only clarifies that
  mapping in the docs.
- **Arbitrary-precision Integer (bignum) is separate.** Closed by
  [ADR-0049](ADR-0049-arbitrary-precision-integer.md); not part of this change.
- **Struct keys are Strings only.** The Syrup dict wire form permits any key
  type, but OCapN Struct requires String keys, so non-String keys are refused
  even though the encoding could carry them.

## Alternatives Considered

- **Two parallel lists (keys, values) under a wrapper struct.** Rejected: it
  does not fit the single-cursor `LazySequence` the borrowed view is built on,
  forcing a bespoke two-cursor walk in both codecs for no benefit.
- **Keys as full `Argument` values.** Rejected: OCapN restricts keys to Strings,
  so a `[]const u8` key is the honest model; carrying an `Argument` key would
  invite representing structs the spec forbids.
- **Implement Null now.** Rejected on evidence: Goblins does not marshal Null
  and the encoding is unsettled upstream, so any choice would be folklore and
  would not interop.

## Consequences

`src/ocapn/model/mod.zig` gains `StructEntry` and the arm; `owned.zig` clones
and frees entries; `view.zig` gains the view entry type, the lazy sequence, the
`fromOwned`/`toOwned` arms, and a `StructEntry` branch in the sequence unwind;
`equality.zig` gains `structsEqualDepth`. Both codecs gain encode and decode
arms (`syrup/encode.zig`, `syrup/decode.zig`, `capnp/encode.zig`,
`capnp/decode.zig`, `capnp/shared.zig`'s `ArgKind`). Tests flip the Syrup refusal
to a round-trip, add a Cap'n Proto round-trip, and add a struct case to the
cross-codec equivalence corpus. The README drops the "Struct not modeled" claim,
states that `.void` is Undefined, and records Null as an unmodeled boundary
(unknown Syrup records project as `Tagged`, not a dedicated Null refuse).
The C ABI and all four bindings project Struct through their ordinary typed
value tree, including nested capability leaves; Struct no longer requires a
raw-frame escape hatch.

## Notes

Relates to ADR-0026 (the hand-rolled Cap'n Proto codec) for the wire
representation, and to ADR-0049 for arbitrary-precision Integer (shipped).
