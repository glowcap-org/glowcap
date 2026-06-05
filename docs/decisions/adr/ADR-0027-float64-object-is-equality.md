---
id: ADR-0027
status: accepted
date: 2026-06-04
tags: [model, equality, conformance, pass-invariant]
decision: "Float64 Pass-Invariant Equality uses Object.is semantics, not IEEE `==`: every NaN bit-pattern is Equal to every other NaN, and `+0.0` is not Equal to `-0.0`. Implemented by collapsing NaN to one Equal class and otherwise comparing raw bits in `model.float64Equal`."
supersedes: []
superseded_by: []
---

# ADR-0027 Float64 Object.is equality

## Context

OCapN's [Model.md § Pass Invariant Equality](../../../conformance/ocapn-spec/upstream/draft-specifications/Model.md)
requires that a value which round-trips the network stays Equal to itself, and
spells the Float64 axis out: it "can be compared by `Object.is`, which preserves
the distinction between 0 and -0 and lack of distinction between any two NaN
values." IEEE `==` gets both cases backwards — `NaN == NaN` is false and
`+0.0 == -0.0` is true — so a comparator built on `==` violates Pass-Invariant
Equality, the conformance authority this repo treats as the oracle
([First Principles](../../../AGENTS.md#first-principles): conformance is
load-bearing; codec-neutral semantics). The `+0`/`-0` distinction is also what
keeps the JSON round-trip invariant honest (Model.md), since the two zeros are
distinct JSON-observable values.

`src/model/equality.zig` is the codec-neutral structural-equality substrate
([ADR-0013](ADR-0013-cross-session-distributed-equality.md)); its `.float64` arm
compared with `x == b.float64`, the wrong axis.

## Decision

`model.float64Equal` in
[`src/model/equality.zig`](../../../src/model/equality.zig) implements the
`Object.is` axis: if either operand is NaN the values are Equal iff *both* are
NaN (collapsing every NaN bit-pattern — quiet, signalling, any payload — to one
Equal class), and otherwise the operands compare by raw bits
(`@as(u64, @bitCast(x)) == @as(u64, @bitCast(y))`), which keeps `+0.0` (all-zero
bits) distinct from `-0.0` (sign bit set). The `.float64` arm of
`argumentsEqual` calls it. No wire field carries equality — this is the
in-memory evidence for the distributed-equality assertions the conformance tests
make on the values the session tables hold.

## Scope (what this does not decide)

- **Float total ordering / sorting.** This decides Equality only, not an order
  over floats; OCapN defines no float ordering for pancake to implement.
- **Container element-order semantics.** List/Struct element comparison stays
  order-sensitive structural equality (unchanged); this ADR is only the Float64
  scalar axis.

## Alternatives Considered

- **IEEE `==`** (the prior code). Rejected: violates Pass-Invariant Equality —
  a NaN payload is not Equal to itself across a round trip, and `+0`/`-0` are
  wrongly conflated.
- **Canonicalize NaN / sign-zero at decode** instead of at compare. Rejected:
  Equality runs on the decoded `f64` and no encoder canonicalizes floats, so the
  fix belongs in the comparator where the semantics are defined, not smeared
  across every codec.

## Consequences

- `model.float64Equal` is the single Float64 comparator; `argumentsEqual` routes
  the `.float64` arm through it.
- Evidence: the `NaN`-equals-`NaN`, `+0`-distinct-from-`-0`, and
  ordinary-magnitude cases in
  [`test/model/equality_test.zig`](../../../test/model/equality_test.zig).

## Notes

- [ADR-0013](ADR-0013-cross-session-distributed-equality.md) owns the
  cross-session distributed-equality model this scalar axis sits inside;
  [ADR-0021](ADR-0021-ocapn-value-tree-breadth.md) owns the value-tree breadth
  that includes `Float64`.
