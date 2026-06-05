---
id: ADR-0021
status: accepted
date: 2026-05-17
tags: [model, codec, syrup-wire, goblins-interop, value-tree]
decision: The codec-neutral `Argument` union admits the OCapN passable value tree Goblins's marshaller emits, so a partner's value cannot crash pancake's decoder. The Syrup codec renders the variants it can represent and refuses the rest loudly with `UnsupportedArgument` rather than dropping them; `float64` is the one admitted variant the encoder does not render. `Null`, `Dict`, `Float32` fidelity, and arbitrary-precision integers are not modeled.
supersedes: []
superseded_by: []
---

# ADR-0021 OCapN value-tree breadth

## Context

Goblins's `^echo` reflects any value its caller sends, and Goblins's CapTP
marshaller emits the full OCapN passable universe (Model.md § Atom + § Container)
as `op:deliver` arguments and resolution payloads. If pancake's value model is
narrower than that universe, an honest Goblins client can hand pancake a value
its decoder has no home for. The [First Principles](../../../AGENTS.md#first-principles)
hold that protocol correctness comes before implementation convenience, and that
a codec parses and renders but does not get to rule a partner's value illegal.
The value model and the Syrup wire sit at different widths; the gap between them
must be a loud, typed boundary, not a silent drop or a panic.

## Decision

The `Argument` union in [`src/model/mod.zig`](../../../src/model/mod.zig) carries
the passable value tree as 14 variants: `bytes`, `symbol`, `reference`, `error`,
`handoff`, `string`, `integer`, `boolean`, `list`, `void`, `float64`, `set`,
`tagged`, and `keyword`. Every value Goblins can marshal therefore has a model
home, so decoding never forces a crash.

The Syrup codec in [`src/codec/syrup/core.zig`](../../../src/codec/syrup/core.zig)
renders the variants it can represent and refuses the rest:

- `writeArgument` encodes `bytes`, `symbol`, `reference`, `string`, `handoff`,
  `integer`, `boolean`, `list`, `void` (`<void>`), `set` (`#…$`), `tagged`
  (`<user-record …>`), and `keyword` (`<kw …>`). `float64` reaches the
  fall-through arm and fails loud with `Error.UnsupportedArgument`; the `error`
  variant has no positional-argument arm and shares that refusal (it rides
  resolutions through the dedicated `resolve:break` path instead).
- The borrowed-view decoder (`readArgument` → `ArgumentView`) lifts the
  byte-atom subset (`bytes` / `string` / `symbol`), references, `<void>`, and
  `<error …>`; a wire shape outside that subset returns `UnsupportedArgument`
  rather than being mis-decoded.

Refusal is loud at both edges. An outbound value the encoder cannot render
surfaces `UnsupportedArgument` to the application; an inbound value the decoder
cannot lift projects to a `protocol_error` `op:abort`
([`src/runtime/abort_projection.zig`](../../../src/runtime/abort_projection.zig))
that closes the session. This is the symmetric-refusal contract from
[ADR-0003](ADR-0003-codec-interoperability-posture.md): a value the model admits
but a codec cannot carry is refused, never dropped, so cross-codec behavior does
not fork on representability.

## Scope (what this does not decide)

- **`float64` rendering.** The variant is modeled but the encoder does not render
  it; the boundary is the loud `UnsupportedArgument` refusal, pinned by the
  fixture in [`test/codec/syrup_test.zig`](../../../test/codec/syrup_test.zig).
- **Variants outside the model.** `Null` (distinct from `void`), `Dict`,
  `Float32` round-trip fidelity, and arbitrary-precision `integer` (the model
  caps at `i64`) are not modeled. A value carrying one is refused at the decode
  boundary, not silently coerced.

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
- The encode breadth (12 rendered variants) is wider than the borrowed-view
  decode breadth (byte atoms, references, `void`, `error`). Shapes between the
  two widths are refused loudly on decode — a named boundary, not an invisible
  one.
- Conformance evidence lives in
  [`test/codec/syrup_test.zig`](../../../test/codec/syrup_test.zig): the rendered
  variants assert against Goblins byte fixtures (`op_deliver_arg_*`); the
  `float64` refusal asserts `UnsupportedArgument`.

## Notes

- [ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the
  symmetric-refusal contract this ADR exercises at the value-tree edge.
