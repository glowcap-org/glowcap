---
id: ADR-0011
status: accepted
date: 2026-05-08
tags: [codec, syrup, wire, pipelining, model, goblins-parity]
decision: The model carries top-level `Get { receiver, field, answer }` and `Index { receiver, index, answer }` arms carrying the OCapN `op:get` / `op:index` wire shapes, and the Syrup codec encodes and decodes both on every profile. A `field` pipeline path-step is a Cap'n Proto-only operand the Syrup decomposer and reference encoders reject loudly; Syrup does not translate it into `op:get`. Serving these ops against a local object model is not implemented — a received op surfaces an application event and records receipt.
supersedes: []
superseded_by: []
---

# ADR-0011 `op:get` and `op:index`

## Context

OCapN's `CapTP Specification.md` (§ `op:get`, § `op:index`) defines two structural operations: project a field by name off a promise resolution or an export, and index a list element. Each follows promise resolutions, inherits rejection reasons, and exports a fresh answer that resolves to the field / index value. Spritely Goblins emits both on the wire (`goblins/ocapn/captp.rkt`). Without model and codec arms for them, a Goblins peer reaching a struct field emits `op:get` and the receiver tears the session down on an unknown record.

There is also a model question. [`src/model/mod.zig`](../../../src/model/mod.zig) carries `PipelineOp.field` as the Cap'n Proto-only structural step of a `PromiseRef` path ([ADR-0007](ADR-0007-promise-pipelining-substrate.md)). `op:get` is the spec's field access. The ADR settles whether Syrup grows a `field`-to-`op:get` translation or keeps the two surfaces apart.

Engages the First Principles [*protocol correctness before convenience*](../../../AGENTS.md#first-principles) — a record the spec defines must decode, not abort — and *fail loud rather than succeed wrong*.

## Decision

### Top-level message arms

[`src/model/mod.zig`](../../../src/model/mod.zig) carries `Get { receiver: Reference, field: []const u8, answer: u64 }` and `Index { receiver: Reference, index: i64, answer: u64 }`. `receiver` is any reference shape — a `promise` (the `<desc:answer>` case) or a `near` / `far` (the export / import case [ADR-0010](ADR-0010-payload-descriptor-discriminator.md) decodes). `index` constrains the spec's unbounded `Integer` to `i64`: a list longer than `i64::MAX` is implausible, and a negative or out-of-range index is out-of-bounds per spec. A wire integer outside `i64` is refused at decode as `MalformedFrame` (`readInteger`), so the session never sees an out-of-range index.

### Syrup carries both ops

[`src/codec/syrup/core.zig`](../../../src/codec/syrup/core.zig) encodes and decodes the spec's 3-operand `<op:get receiver field answer>` and `<op:index receiver index answer>` records, admitted on both `pre_spec` and `v1_0` (`AdmittedMessage.get` / `.index`). The shapes are identical across profiles — there are no Goblins-canonical extensions to these ops.

### `field` stays Cap'n Proto-only

`PipelineOp.field` is structural navigation with no `op:deliver` analog, so the Syrup decomposer ([`decomposeOutboundDeliver`](../../../src/runtime/pipeline.zig)) rejects a `field` step loudly with `UnsupportedPipelineOp`, and the reference encoders reject a promise target carrying a non-empty path with `UnsupportedReference`. Syrup does **not** rewrite a `field` step into a chained `op:get`: OCapN is methodic, and a structural path-step rides only a native Cap'n Proto frame, which is not implemented. A `call` step decomposes into chained `op:deliver` per [ADR-0007](ADR-0007-promise-pipelining-substrate.md); a `field` step has no chain.

### Serving is not implemented

Computing a field / index result against a local object model is not implemented. A received `op:get` / `op:index` surfaces an application event (`EventKind.get` / `.index`, [`src/runtime/mod.zig`](../../../src/runtime/mod.zig)) and records receipt through `recordRecv`; the session opens no answer row and the runtime synthesizes no resolution. The application owns dispatch.

## Scope (what this does not decide)

- **The Cap'n Proto codec is not implemented** — the only shape that would carry a `field` path-step as a native frame operand; codec posture is [ADR-0003](ADR-0003-codec-interoperability-posture.md).
- **`op:untag`** — the spec's third structural op is not implemented; pancake follows the OCapN community rather than leads.
- **Actor-model synthesis** — running a method and materializing the field / index value against a resolution is not implemented.

## Alternatives Considered

- **Collapse `PipelineOp.field` into `op:get`.** Rejected: it would allocate a fresh answer per `field` step and erase the native single-frame path the reserved Cap'n Proto slot preserves. The two surfaces sit at different layers.
- **Overload `op:deliver` with a sentinel method name.** Rejected: the wire shape is incompatible with the spec's 3-operand `op:get`, so pancake could not decode a Goblins-emitted `op:get`; and a sentinel symbol reads as a spec proposal, not an implementation choice.
- **`u64` for `index`.** Rejected: it discards the sign axis the spec's `Integer` admits, silently casting a negative wire integer to garbage.
- **Defer the wire arms until serving lands.** Rejected: decoding the record is independent of serving. Without the arms a Goblins `op:get` tears the session down; with them the receipt is recorded and the gap is a missing resolution, not a lost connection.

## Consequences

- `Message.get` and `Message.index` arms plus matching `view` arms; the Syrup label set and encode / decode / view projection grow `op:get` and `op:index`.
- The session records receipt of an inbound `op:get` / `op:index` without opening an answer row; the runtime surfaces it as an application event.
- Conformance under [`src/conformance/`](../../../src/conformance/mod.zig) exercises both ops across their receiver shapes; Goblins fixtures pin the byte shapes under `zig build oracle-check`.

## Forward compatibility

`op:untag` follows the same 3-operand `<receiver … answer>` shape, so its arm and codec dispatch land the same way when its semantics settle. Actor-model synthesis slots into the event-dispatch path without reshaping the wire or the model arms.

## Notes

[ADR-0007](ADR-0007-promise-pipelining-substrate.md) is supplemented, not superseded: its `call`-step decomposition stands, and its `field`-step rejection is the rule this ADR builds the `op:get` surface beside. [ADR-0010](ADR-0010-payload-descriptor-discriminator.md) makes the export / import receiver of an `op:get` reachable on the wire. [ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) and [ADR-0003](ADR-0003-codec-interoperability-posture.md) are unaffected.
