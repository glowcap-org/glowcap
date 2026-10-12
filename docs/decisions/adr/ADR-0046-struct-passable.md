---
id: ADR-0046
status: accepted
date: 2026-06-11
tags: [model, codec, syrup, capnp, conformance, data-model]
decision: "The OCapN Struct passable is modeled as an ordered-on-the-wire, equality-unordered sequence of (String key, Value) entries (model.StructEntry), carried by both codecs (Syrup as a dict {} and Cap'n Proto as a composite list of entry structs) with String-only keys, duplicate keys refused at decode, canonical key order on encode, and order-independent structural equality. Undefined is already the existing .void arm (Goblins marshals the unspecified value as the <void> record). Null stays unmodeled because Goblins has no Null marshalling and the upstream encoding is unsettled."
supersedes: []
superseded_by: []
---

# ADR-0046 Struct passable

## Context

The OCapN passable data model has a Struct type: an unordered collection of
(key, value) pairs where each key is a String (Model.md § Struct). glowcap
modeled every other passable but refused Struct. A complete OCapN data model
needs Struct, and it touches the model type, both codecs, structural equality,
and conformance.

Goblins is the wire authority for the neighboring atoms. Its CapTP marshalling
(`conformance/spritely-goblins/upstream/goblins/ocapn/captp.rkt`) marshals a
hash straight to a Syrup dictionary, marshals the unspecified value `(void)` as
the `<void>` record, and has no Null case. Undefined is therefore glowcap's
existing `.void` arm, the `<void>` record both peers speak, and Null has no
settled wire encoding. An invented one could not interop. Arbitrary-precision
Integer is a settled gap (Goblins uses Racket bignums), but it is a scalar
extension orthogonal to Struct and is tracked separately.

## Decision

Struct is one new `Argument` arm in both the owned model and the borrowed view.

The owned model gains `model.StructEntry { key: []const u8, value: Argument }`
and the arm `Argument.@"struct": []const StructEntry`. The key is an OCapN
String. The borrowed view gains `view.StructEntry` and `view.StructEntries`, a
`LazySequence(model.StructEntry, view.StructEntry)`, so a struct stays a
borrowed, single-cursor walk over the wire region until `toOwned` materializes
it, the same zero-allocation projection list and set use. Modeling entries as a
sequence, not two parallel key/value lists, makes the single-cursor lazy view
fit both codecs.

Both codecs carry it. Syrup encodes a struct as a dictionary `{ key value … }`
and decodes `{` back to the arm. Keys are written as Syrup strings, and entries
are emitted in canonical order: sorted by the fully-encoded key, matching the
upstream Syrup encoder (`conformance/syrup/upstream/impls/python/syrup.py`).
Cap'n Proto adds `ArgKind.@"struct"` and carries it as a composite list of entry
structs, each a two-pointer struct holding the key text and the value Argument,
mirroring how `.tagged` is carried.

The typed C waist carries the same entry sequence without adding a second
recursive ABI type: `GLOWCAP_ARG_STRUCT` uses `GlowcapArgument.items` as an
even-length alternating sequence of `_STRING` keys and values. The shared
marshaller enforces the even count, String-only keys, and uniqueness once.
Rust, TypeScript, Python, and Racket expose only idiomatic wrappers over that
one contract.

Decode enforces the spec's key rules. A non-String key and a duplicate key are
refused at the codec boundary where bytes are parsed, projected as the existing
`UnsupportedArgument` / `MalformedFrame` refusals. Equality is
order-independent: two structs are Equal when they have the same length and
every key in one is present in the other with an equal value
(`model.equality.structsEqualDepth`), the keyed analogue of the order-agnostic
set equality. Canonical encode order plus order-independent equality give the
round-trip the spec requires: a struct may round-trip into a different key order
and still be Equal.

## Scope (what this does not decide)

- **Null stays unmodeled.** Goblins has no Null marshalling and the upstream
  encoding is unsettled (Model.md marks the Guile/Python mappings "tentative" /
  "imported"). Unknown Syrup records project as `Tagged` (break/exception
  leniency), with no dedicated Null refusal.
- **Undefined is not a new arm.** It is the existing `.void` arm, the `<void>`
  record Goblins uses for the unspecified value.
- **Arbitrary-precision Integer (bignum)** is decided in
  [ADR-0049](ADR-0049-arbitrary-precision-integer.md).
- **Struct keys are Strings only.** The Syrup dict wire form permits any key
  type, but OCapN Struct requires String keys, so non-String keys are refused.

## Alternatives Considered

- **Two parallel lists (keys, values) under a wrapper struct.** Rejected: it
  does not fit the single-cursor `LazySequence` the borrowed view is built on
  and would force a two-cursor walk in both codecs.
- **Keys as full `Argument` values.** Rejected: OCapN restricts keys to Strings,
  so a `[]const u8` key models it, and an `Argument` key would allow structs the
  spec forbids.
- **Implement Null now.** Rejected: Goblins does not marshal Null and the encoding is
  unsettled upstream, so any choice would not interop.

## Consequences

`src/ocapn/model/mod.zig` gains `StructEntry` and the arm. `owned.zig` clones
and frees entries. `view.zig` gains the view entry type, the lazy sequence, the
`fromOwned`/`toOwned` arms, and a `StructEntry` branch in the sequence unwind.
`equality.zig` gains `structsEqualDepth`. Both codecs gain encode and decode
arms (`syrup/encode.zig`, `syrup/decode.zig`, `capnp/encode.zig`,
`capnp/decode.zig`, `capnp/shared.zig`'s `ArgKind`). Tests flip the Syrup
refusal to a round-trip, add a Cap'n Proto round-trip, and add a struct case to
the cross-codec equivalence corpus. The README states that `.void` is Undefined
and records Null as an unmodeled boundary. The C ABI and all four bindings
project Struct through their typed value tree, including nested capability
leaves, with no raw-frame escape hatch.

## Notes

Relates to ADR-0026 (the hand-rolled Cap'n Proto codec) for the wire
representation, and to ADR-0049 for arbitrary-precision Integer (shipped).
