---
id: ADR-0023
status: accepted
date: 2026-05-17
tags: [model, codec, syrup, wire, references, goblins-parity]
decision: `NearRef` carries a `kind: NearKind { object, promise }` discriminant, and the Syrup payload-reference encoder dispatches on it — `.object` emits `<desc:import-object>`, `.promise` emits `<desc:import-promise>` — so a stateless codec renders a promise-shaped local export (vow / resolver-callback / handoff-imported promise) as a promise descriptor instead of always object. Default is `.object` so ordinary call sites stay terse. Additive model widening; no profile-name bump.
supersedes: []
superseded_by: []
---

# ADR-0023 NearRef kind on the wire

## Context

[ADR-0010](ADR-0010-payload-descriptor-discriminator.md) settles the decode side: with the perspective flip, `<desc:import-object>` and `<desc:import-promise>` lift to a *receiver-perspective* `far` import whose `ImportKind` preserves the object/promise tag. The encode side is the mirror — when a local export (a `near`) goes out in payload position, the codec must render the descriptor that matches the export's nature.

Goblins distinguishes the two at this position: `outgoing-pre-marshall!` (`goblins/ocapn/captp.rkt`) emits `<desc:import-object>` for a live local object and `<desc:import-promise>` for an unresolved local promise. A peer that branches on the tag treats a promise-shaped vow as a promise. If the codec always emitted object, a Goblins partner's import-table representation of a vow would be wrong.

Pancake exports promise-shaped references in three flows: the V1.0 resolver-callback advertised in an `op:deliver`'s `resolve_me_desc`, the bootstrap-fetch resolver the partner settles, and a handoff vow. The codec is stateless ([ADR-0003](ADR-0003-codec-interoperability-posture.md)) and cannot ask the session "is this export a promise?" at encode time, so the discriminant must ride the model.

Engages the First Principles [*session state is authoritative*](../../../AGENTS.md#first-principles) and *codecs parse and render but do not own authority* — the kind travels on the model, never via a session lookup at encode time.

## Decision

### `NearKind` on `NearRef`

[`src/model/mod.zig`](../../../src/model/mod.zig) gives `NearRef` a `kind: NearKind { object, promise }` defaulting `.object`, with constructors `NearRef.object(id)` and `NearRef.promise(id)`. The default keeps every non-promise struct-literal call site terse.

### Encoder dispatch

`writePayloadReference` in [`src/codec/syrup/core.zig`](../../../src/codec/syrup/core.zig) dispatches on the kind: `.object` → `<desc:import-object N>`, `.promise` → `<desc:import-promise N>`. The same dispatch reaches every payload position — fulfill arguments, `op:listen` slots, `op:deliver` args.

### Promise-shaped export call sites

The runtime constructs `NearRef.promise` exactly at the sites that export a promise: the V1.0 resolver-callback `resolve_me_desc` ([`src/runtime/mod.zig`](../../../src/runtime/mod.zig)) and the bootstrap-fetch resolver ([`src/runtime/fetch.zig`](../../../src/runtime/fetch.zig)). The session does not branch on `NearKind`; the export's promise nature is a model fact set at the construction site.

### Perspective and round-trip

The decoder flips `<desc:import-object>` / `<desc:import-promise>` to the receiver's `far.object` / `far.promise` per [ADR-0010](ADR-0010-payload-descriptor-discriminator.md); `<desc:export>` flips to a `near` and carries no object/promise signal, so a decoded `near` defaults `.object`. A `NearRef.promise` sent in payload position arrives as the partner's `FarRef` with its `promise` kind intact — the arm flips with the perspective crossing, but the object/promise kind survives because it rides the model field.

### No profile-name bump

The Syrup wire already carries both `<desc:import-object>` and `<desc:import-promise>` (the decode side this ADR mirrors). Emitting the promise arm widens the model additively without changing the meaning of an existing wire shape, so the profile name does not change — the same additive posture [ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) and [ADR-0021](ADR-0021-ocapn-value-tree-breadth.md) use.

## Scope (what this does not decide)

- **Session-side branching on `NearKind`.** The session does not validate or dispatch on it; a promise-shaped export is constructed at the encode site, not flipped by the session. Not decided here.
- **Cap'n Proto encode of the kind.** The Cap'n Proto codec carries the kind via a promise bit on its word-shaped reference and applies the same perspective flip ([ADR-0010](ADR-0010-payload-descriptor-discriminator.md)); the wire-tag-vs-bit difference is a codec detail, not a model one.

## Alternatives Considered

- **The codec consults the session at encode time** ("is this export a promise?"). Rejected: codecs do not own authority. The codec trait would have to take a session handle and every codec would know about session tables.
- **A separate `Reference` variant for a local promise.** Rejected: it duplicates `near` while the model already has the `near | far | promise | sturdy | broken` axis. The kind is sub-axis information that fits on `NearRef`, mirroring `FarRef.kind`.
- **Always emit `<desc:import-object>`.** Rejected: it corrupts a spec-strict partner's representation of a promise-shaped vow, the precise case the resolver-callback and handoff flows export.

## Consequences

- `NearKind` enum, the `NearRef.kind` field, and the `object` / `promise` constructors are part of the model surface.
- `writePayloadReference` dispatches on the kind; the resolver-callback and bootstrap-fetch sites construct `NearRef.promise`.
- A cross-codec conformance scenario under [`src/conformance/`](../../../src/conformance/mod.zig) round-trips a `near`-promise through encode and decode; the `<desc:import-promise>` byte shape is pinned against Goblins fixtures under `zig build oracle-check`.

## Forward compatibility

`NearKind` is additive, so a future near-axis (transient debug ref, sturdy-by-id local ref) lands without breaking existing matches. The promise kind carries the same content across both the Syrup and Cap'n Proto codecs because it rides the model field, not the wire-label string.

## Notes

[ADR-0010](ADR-0010-payload-descriptor-discriminator.md) is the decode-side counterpart this ADR mirrors on encode. [ADR-0008](ADR-0008-goblins-canonical-syrup-wire-profile.md) and [ADR-0021](ADR-0021-ocapn-value-tree-breadth.md) are the additive Syrup-widening precedent. [ADR-0007](ADR-0007-promise-pipelining-substrate.md) owns the resolver-callback drain trigger a promise-shaped export rides. [ADR-0003](ADR-0003-codec-interoperability-posture.md) is the stateless-codec constraint that rules out an encode-time session lookup.
