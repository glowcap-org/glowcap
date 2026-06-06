---
id: ADR-0015
status: accepted
date: 2026-05-12
tags: [handshake, crypto, ed25519, signing, peer-auth, start-session]
decision: Peer authentication at `op:start-session` is an Ed25519 signature over the Goblins-canonical `<my-location $acceptable-location>` bytes. The core signs with a caller-seeded key, verifies the partner signature against the decoded frame view, and stores no key material; a verification failure is a loud error. Wire confidentiality is a netlayer concern and is not implemented.
supersedes: []
superseded_by: []
---

# ADR-0015 Handshake signing

## Context

`op:start-session` carries a `session_pubkey` and an `acceptable_location_sig` ([ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md)). The signature authenticates the peer: it binds the claimed key to the location the peer offered, so a partner cannot replay or forge another peer's location. Goblins fixes both the algorithm (Ed25519) and the signing domain — `pk-sign` / `pk-verify` run over the wrapped `<my-location $acceptable-location>` record, not the raw locator bytes — so the wire half is a transcription against the Goblins reference and the OCapN CapTP spec § op:start-session.

Engages the [First Principles](../../../AGENTS.md#first-principles) *protocol correctness and capability semantics before convenience*, *the portable core stays sync and no-I/O* (the entropy that mints a key is the adapter's), *session state is authoritative* (the session owns capability state, not key custody), and *fail loud rather than succeed wrong* (a bad signature aborts).

## Decision

**Primitives.** [`src/foundation/crypto.zig`](../../../src/foundation/crypto.zig) owns the Ed25519 math: `SecretKey` / `PeerKey` / `Signature`, `sign` / `verify`, and `SecretKey.fromSeed`. Everything is pure computation — no allocation, no I/O, no global state — and compiles to `wasm32` unchanged. `fromSeed` is the entropy boundary: the core reconstructs a key from a caller-supplied 32-byte seed and never generates randomness itself, because generating a seed is I/O an adapter owns.

**Signing domain.** The signature is over the Goblins-canonical `<my-location $acceptable-location>` record produced by [`canonicalLocationSignedBytes`](../../../src/codec/syrup/) in the Syrup codec ([`src/codec/syrup/core.zig`](../../../src/codec/syrup/core.zig)). Signing the wrapped record rather than the bare locator matches Goblins's `pk-sign` domain, so a Goblins peer verifies a pancake signature and pancake verifies a Goblins one. This one function is the single canonical domain both the signer and the verifier call.

**Sign and verify.** [`src/engine/pairing.zig`](../../../src/engine/pairing.zig) `pairedWithKeys` derives each side's key from its seed, signs that side's canonical location bytes, and drives the keyed handshake. `verifyAndDrainEvents` verifies the partner signature against the **decoded** frame view (zero-copy): only the canonical signed bytes are materialized to verify against, and the sole fixed-width boundary is `crypto.PeerKey.fromSlice` / `Signature.fromParts` taking the wire-borrowed key / signature halves into their by-value forms. The session stores no key bytes — verification reads the decoded view and discards. A failure surfaces as `Error.InvalidStartSessionSignature`, projected as the [`AbortKind.invalid_start_session_signature`](../../../src/model/mod.zig) typed abort.

## Scope (what this does not decide)

- Wire confidentiality (TLS or any transport encryption) is a netlayer concern and is not implemented. CapTP authenticates the peer here; encrypting the bytes is an adapter / transport's job.
- The shipped Zig net adapter is a testing TCP surface; driving the keyed
  handshake over a production transport — and the connection lifecycle around it
  — is an adapter concern.
- The handoff `desc:sig-envelope` certificates that reuse the same crypto primitives — [ADR-0009](ADR-0009-three-party-handoff-substrate.md).

## Alternatives Considered

- **Sign the raw `acceptable_location` bytes instead of the wrapped record.** Rejected: Goblins signs the wrapped `<my-location …>` record; matching its domain is what lets the two implementations verify each other.
- **Generate the per-session key inside the core.** Rejected: entropy is I/O. `fromSeed` keeps the core deterministic and wasm-clean, with seed provenance at the caller.
- **Store the partner key on the session after verifying.** Rejected: authority lives in references, never in a key. The session is authoritative for capability state, not key custody; verification reads the decoded view and keeps nothing.
- **Reuse one per-peer-identity key across sessions.** Rejected: the spec mints a fresh key per session; `pairedWithKeys` takes per-session seeds.

## Consequences

- `foundation.crypto` owns the Ed25519 math with no codec dependency; its hand-rolled canonical serializations are byte-identical to the Syrup encoder and pinned by an oracle fixture.
- `canonicalLocationSignedBytes` is the one signing domain both `sign` and `verify` call, so signer and verifier cannot drift.
- `pairedWithKeys` / `verifyAndDrainEvents` are the keyed-handshake fixtures; verification runs against the decoded view with no session storage of key material.
- A bad signature produces `Error.InvalidStartSessionSignature` and the `AbortKind.invalid_start_session_signature` typed abort — observable in a scenario, never a silent pass.
- Conformance covers a keyed handshake that verifies and a tampered-signature handshake that aborts.

## Forward compatibility

The signing domain and the verify-against-decoded-view path are final. A netlayer that adds wire confidentiality wraps the transport without touching peer authentication — CapTP keeps authenticating the peer with this signature regardless of whether the bytes underneath are encrypted.

## Notes

[ADR-0006](ADR-0006-handshake-substrate-and-bootstrap-fetch.md) owns the `op:start-session` substrate this signature authenticates. [ADR-0009](ADR-0009-three-party-handoff-substrate.md) reuses the same `foundation.crypto` primitives for handoff certificates. [ADR-0003](ADR-0003-codec-interoperability-posture.md) owns the Syrup profile the canonical bytes encode under.
