---
id: ADR-0008
status: accepted
date: 2026-05-05
tags: [syrup, wire-profile, gc, reference-counting, abort, goblins-parity]
decision: The Goblins-canonical Syrup profile carries split GC — `op:gc-exports` (parallel position + wire-delta lists) and `op:gc-answers` (position list) — with wire-delta reference counting in the import / export / answer tables and fail-loud underflow. There is no `op:release`. `op:abort` carries a typed `AbortKind` taxonomy that `v1_0` projects to a spec-compliant single string and `pre_spec` carries structured.
supersedes: []
superseded_by: []
---

# ADR-0008 Goblins-canonical Syrup wire profile + reference counting

## Context

Goblins garbage-collects references with two operations and a batched `wire-delta`, not a single per-reference release. A peer legitimately re-sends the same import and expects batched `op:gc-exports` carrying positive wire-deltas. The OCapN `CapTP Specification.md` (§ `op:gc-exports`, § `op:gc-answers`, § `op:abort`) and Goblins's `captp.rkt` pin the wire shapes precisely, so the wire half is a transcription. The session-state half — where the counts live, what underflow does — is pancake's call.

`op:abort` rides the same profile. Goblins emits a single-string `<op:abort reason>`. pancake carries a typed kind on the model surface and projects it per profile, so a pancake↔pancake session can route abort decisions on the kind while a pancake↔Goblins session stays spec-strict.

Engages the First Principles *session state is authoritative* (counts live in the session tables, not the codec), *conformance is load-bearing* (the shapes are pinned against Goblins fixtures), and *fail loud rather than succeed wrong* (underflow is an error, never a silent clamp).

## Decision

### Split GC wire shapes

`op:gc-exports` is two **parallel** lists — `position-list[i]` is the export id, `delta-list[i]` is the count of references to it the sender has dropped since its last `op:gc-exports` for that id. The receiver decrements its export count by the delta; at zero the export is collected. `op:gc-answers` is a single position list — promises are single-reference per answer-pos, so "done with N" needs no delta, and a gc'd answer-pos becomes reusable. The model mirrors the wire ([`src/ocapn/model/mod.zig`](../../../src/ocapn/model/mod.zig)):

```zig
pub const GcExport = struct { positions: []const u64, deltas: []const u64 };
pub const GcAnswer = struct { positions: []const u64 };
```

There is no `op:release` arm at any layer.

### Wire-delta reference counting

The import, export, and answer tables in [`src/ocapn/session/mod.zig`](../../../src/ocapn/session/mod.zig) carry a wire-delta count. Applying `op:gc-exports` validates then applies atomically: a `positions`/`deltas` length mismatch and a count underflow are both loud errors (`GcUnderflow` and siblings), surfaced — never saturating-subtracted. Underflow is a peer-or-protocol bug; absorbing it would hide the bug class. This is the behavior the C ABI dogfood pins: a fresh peer fed `op:gc-answers` for an answer-pos it never owned rejects the frame and projects an abort.

### Typed abort taxonomy

`AbortReason { kind: AbortKind, message: []const u8 }` carries a `non_exhaustive`-style `AbortKind` enum. Projection per profile:

- **`pre_spec`:** carries both kind and message; a pancake↔pancake session routes on the kind.
- **`v1_0`:** emits the single-string `<op:abort message>` the spec requires. The kind rides as a discoverable prefix — `"<KindName>: <message>"` — which the Syrup decoder matches back to a kind, falling to `.other` when no prefix matches. The wire-string format is the codec's in both directions; the model carries only the typed `AbortReason`. Spec-strict on the wire, typed within pancake.

The taxonomy spans the conditions the protocol core originates (`protocol_error`, `malformed_frame`, the `*_not_negotiated` family, `resource_exhausted`, `version_mismatch`, `invalid_start_session_signature`, `invalid_handoff_signature`, `handoff_replay`) **and** the connection-lifecycle conditions an adapter detects (`connection_lost`, `graceful_shutdown`, `crossed_hellos`, `timeout`). The no-I/O core does not detect a lost socket or a crossed-hellos collision — those are dial/transport concerns an adapter owns — but the kind and its wire projection live here so an adapter can project a *typed* abort through the one shared projection path rather than inventing its own wire shape. [`src/ocapn/engine/abort_projection.zig`](../../../src/ocapn/engine/abort_projection.zig) maps a rejected inbound frame (codec-malformed or session-refused) to the typed `op:abort` before the error surfaces.

## Scope (what this does not decide)

- The handoff cryptographic suite and three-party protocol — [ADR-0009](ADR-0009-three-party-handoff-substrate.md).
- Promise pipelining queue/drain and `op:listen` — [ADR-0007](ADR-0007-promise-pipelining-substrate.md).
- The session table caps that bound these accumulators against a hostile peer — [ADR-0025](ADR-0025-session-table-cap-policy.md).
- Adapter detection of connection loss / crossed hellos / graceful shutdown. The
  core carries the kinds and projects them; an adapter decides when to raise
  them. The testing TCP adapter is intentionally minimal, so these kinds remain
  production-transport policy rather than core behavior.

## Alternatives Considered

- **Keep a single `release` operation with synthesized counters.** Rejected: Goblins's wire-delta is batched (one message, many ids); per-id release loses the batching and keeps pancake diverging from Goblins on `v1_0`.
- **One combined `gc` message carrying exports and answers.** Rejected: the wire is two operations; combining them forces a split-on-emit / merge-on-receive translation with no benefit.
- **List-of-pairs for `op:gc-exports`.** Rejected: the wire is two parallel lists; matching that shape is one allocation per side instead of per-element transposition.
- **Saturating subtract on underflow.** Rejected: underflow is always a bug; loud failure makes it observable in a scenario instead of in a deploy.
- **A non-spec kind field on the `v1_0` wire.** Rejected: `v1_0` is a single string operand; the prefix-in-string projection keeps it spec-strict while preserving the model-side kind.

## Consequences

- The model carries `GcExport`, `GcAnswer`, `AbortKind`, and `AbortReason`; there is no release arm to remove because the Zig tree never shipped one.
- The session tables own the counts; `op:gc-exports` / `op:gc-answers` dispatch validates-then-applies and fails loud on underflow / length mismatch.
- A `wire_delta` feature gate refuses the GC shapes on a session that did not negotiate them (`wire_delta_not_negotiated`).
- The `op:gc-exports`, `op:gc-answers`, and `op:abort` byte shapes are checked
  against the in-tree Syrup oracle fixtures under `zig build oracle-check`.

## Forward compatibility

The three wire shapes are final. A spec-level change to the abort reason reshapes only the `v1_0` projection of `AbortKind`, not the model. The wire-delta model is per-id additive: a future single-message flush of many ids is a batching optimization, not a wire change. New `AbortKind` variants land additively; the `"<KindName>: <message>"` prefix convention is the stable contract a peer parses.

## Notes

[ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the profile posture this shape sits inside. [ADR-0010](ADR-0010-payload-descriptor-discriminator.md) and [ADR-0021](ADR-0021-ocapn-value-tree-breadth.md) widen the same Syrup profile additively without a name bump.
