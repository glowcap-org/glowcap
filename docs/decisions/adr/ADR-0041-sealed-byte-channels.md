---
id: ADR-0041
status: accepted
date: 2026-10-19
tags: ["captp", "handshake", "identity", "transport", "relay", "keyed-tcp", "noise", "browser"]
decision: "The sealed transport symbols use Noise_XK_25519_ChaChaPoly_BLAKE2s over a byte pipe."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0041 Sealed byte channels

## Context

A signed hello on cleartext TCP does not prevent replay or an intermediary from reading and modifying traffic. A byte relay should not need protocol authority to carry a confidential session.

## Decision

The sealed transport symbols use Noise_XK_25519_ChaChaPoly_BLAKE2s over a byte pipe. The pure state machine and record framing remain below CapTP. The Host owns the sealed channel and supplies its actual authenticated-channel proof.

The durable Ed25519 identity maps to an X25519 static key. That map loses an Edwards sign bit, so handshake payloads additionally carry the exact Ed25519 key and its signature over the domain-separated identity, role, static key and initial transcript context. The dialer checks the exact expected responder identity.

The prologue binds the transport symbol and responder designator. After the handshake, bounded length-prefixed AEAD records carry the byte stream. Large CapTP frames can span records. Handshake failure closes the channel without downgrade or admission of CapTP traffic.

Handshake secrets are transient and cleared on completion. Sealed channels alone pay for their channel and staging storage. The borrowed-buffer contract remains explicit at decryption and encryption boundaries.

## Alternatives and consequences

Noise IK saves a setup round trip but exposes the recorded first-message initiator identity after later responder static-key compromise. XK was chosen for its different identity-hiding tradeoff. A second static key in a locator hint would make dial-by-key require extra discovery state.

The channel does not hide timing, volume or endpoint availability, and it does not prevent a peer from separately offering an unsealed address. There is no outside CapTP peer speaking these symbols and no independent security audit implied by passing test vectors.

## Evidence

[Noise vectors](../../../test/foundation/noise_test.zig) check the selected suite byte for byte. [Sealed-channel tests](../../../test/driver/sealed_channel_test.zig) cover exact-key substitution, replay and provenance. Live loopback, C ABI and relay checks cover the integrated paths named in [stability](../../stability.md).
