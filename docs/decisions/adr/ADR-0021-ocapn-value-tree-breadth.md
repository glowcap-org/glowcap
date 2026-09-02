---
id: ADR-0021
status: accepted
date: 2026-05-17
tags: [model, codec, syrup-wire, goblins-interop, value-tree]
decision: The codec-neutral `Argument` union admits the OCapN passable value tree Goblins's marshaller emits, so a partner's value cannot crash glowcap's decoder. The Syrup codec renders every modeled positional passable (`float64` included, as the canonical `'D'` + big-endian binary64) and Integer is arbitrary-precision (ADR-0049). Struct ships as the keyed-dictionary passable (ADR-0046). A value *outside* the model (`Null`, `Float32` fidelity) has no model home; inventing Null would not interop until upstream encoding settles.
supersedes: []
superseded_by: []
---

# ADR-0021 OCapN value-tree breadth

## Context

Goblins's `^echo` reflects any value its caller sends, and Goblins's CapTP
marshaller emits the full OCapN passable universe (Model.md § Atom + §
Container) as `op:deliver` arguments and resolution payloads. If glowcap's value
model is narrower than that universe, an honest Goblins client can hand glowcap
a value its decoder has no home for. The
[First Principles](../../../AGENTS.md#first-principles) hold that protocol
correctness comes before implementation convenience, and that a codec parses and
renders but does not get to rule a partner's value illegal. The value model and
the Syrup wire sit at different widths; the gap between them must be a loud,
typed boundary, not a silent drop or a panic.

## Decision

The `Argument` union in
[`src/ocapn/model/mod.zig`](../../../src/ocapn/model/mod.zig) carries the
passable value tree as 14 variants: `bytes`, `symbol`, `reference`, `error`,
`handoff`, `string`, `integer`, `boolean`, `list`, `void`, `float64`, `set`,
`tagged`, and `keyword`. Every value Goblins can marshal therefore has a model
home, so decoding never forces a crash.

The Syrup renderer in
[`src/ocapn/codec/syrup/encode.zig`](../../../src/ocapn/codec/syrup/encode.zig)
and lifter in
[`src/ocapn/codec/syrup/decode/values.zig`](../../../src/ocapn/codec/syrup/decode/values.zig)
cover every modeled positional passable:

- `writeArgument` encodes `bytes`, `symbol`, `reference`, `string`, `handoff`,
  `integer`, `float64` (`'D'` + 8 bytes IEEE-754 big-endian), `boolean`, `list`,
  `void` (`<void>`), `set` (`#…$`), `tagged` (`<user-record …>`), and `keyword`
  (`<kw …>`). The `error` variant has no positional-argument arm: it rides
  resolutions through the dedicated `resolve:break` path, so a positional
  `.error` reaches the fall-through and refuses loudly.
- The neutral decoder (`readNeutralArgument`) lifts the same variants on the way
  in, including `float64` from the `'D'` marker; a wire shape with no model home
  returns `UnsupportedArgument` rather than being mis-decoded.

Refusal is loud at both edges. An outbound value the encoder cannot render
surfaces `UnsupportedArgument` to the application; an inbound value the decoder
cannot lift projects to a `protocol_error` `op:abort`
([`src/ocapn/engine/abort_projection.zig`](../../../src/ocapn/engine/abort_projection.zig))
that closes the session. This is the symmetric-refusal contract from
[ADR-0003](ADR-0003-codec-interoperability-posture.md): a value the model admits
but a codec cannot carry is refused, never dropped, so cross-codec behavior does
not fork on representability.

## Scope (what this does not decide)

- **Variants outside the model.** `Null` (distinct from `void`) has no model
  arm; inventing one waits on upstream encoding and Goblins marshalling
  ([ADR-0046](ADR-0046-struct-passable.md) Scope). `Float32` round-trip fidelity
  is not modeled. Struct (the keyed dictionary) and arbitrary-precision Integer
  ship ([ADR-0046](ADR-0046-struct-passable.md),
  [ADR-0049](ADR-0049-arbitrary-precision-integer.md)). Unknown Syrup records
  project as `Tagged` (Goblins break/exception leniency); that is not a
  dedicated Null refuse.

## Alternatives Considered

- **Model only the variants the codec carries.** Rejected: a value outside the
  model has nowhere to land, so a partner could drive the decoder into undefined
  territory. The model must be at least as wide as the value universe even where
  the wire path is narrower.
- **Silently drop or coerce unrepresentable values.** Rejected: a dropped
  argument changes the call the partner made; loud refusal keeps both state
  machines honest.

## Consequences

- The `Argument` union is the single codec-neutral value vocabulary; a new codec
  grows arms against the same union.
- The Syrup encode and neutral-decode breadths both match the modeled positional
  passables. Residuals outside the model are `Null` (not modeled) and `Float32`
  fidelity: named boundaries, not invisible ones. Struct and Integer/bignum
  are in-model per ADR-0046 and ADR-0049.
- Conformance evidence lives in
  [`test/codec/syrup/`](../../../test/codec/syrup/): the
  rendered variants assert against the glowcap-authored Syrup corpus
  (`op_deliver_arg_*`); `float64` pins the canonical `'D'` + big-endian binary64
  bytes and round-trips NaN and signed zero bit-for-bit.

## Float64 equality

Float64 Pass-Invariant Equality uses `Object.is` semantics, not IEEE `==`: every
NaN bit-pattern is Equal to every other NaN, and `+0.0` is not Equal to `-0.0`.
`model.float64Equal` implements it by collapsing every NaN to one Equal class
and otherwise comparing raw bits. This is the equality axis Model.md requires
for the passable value tree, and it is what the `float64` round-trip test pins
bit-for-bit.

## Notes

- [ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the
  symmetric-refusal contract this ADR exercises at the value-tree edge.
