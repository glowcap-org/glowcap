---
id: ADR-0001
status: accepted
date: 2026-10-19
tags: ["codec", "syrup", "capnp", "wire-profile", "goblins-interop", "captp-version", "session", "engine"]
decision: "Codecs project one codec-neutral model and receive the protocol version for each operation."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0001 Codec profiles and negotiation

## Context

A peer must be able to greet a Goblins implementation and another glowcap build through the same session API. Serialization, protocol semantics and optional features can change independently.

## Decision

Codecs project one codec-neutral model and receive the protocol version for each operation. They hold no session authority. Version, codec and feature negotiation remain separate axes.

Every hello uses the shared baseline Syrup grammar. Signed locator hints advertise preferences, and symmetric negotiation fixes the pair at the handshake boundary. An unknown version or codec offer falls back to the baseline on that axis. Unknown feature names are ignored, while an unreadable feature list refuses.

The baseline is the pinned OCapN/Goblins wire, not a declaration of upstream maturity. Private version and codec offers include fingerprints generated from the bytes of a message corpus. Builds with different private wires cannot silently negotiate the same profile.

## Alternatives and consequences

A global codec posture would couple independent choices. Sniffing a greeting's encoding would make protocol negotiation depend on accidental byte patterns. A manually bumped private version can be forgotten, and hashing source would split builds whose wire is unchanged.

The corpus identifies encoded forms, not every semantic or decoder change. A wire change outside its coverage needs a new case. Application protocols retain their own compatibility contracts. There is no live-session renegotiation.

## Evidence

The negotiation scenarios, codec round trips and generated wire corpus run through `zig build test` and `zig build oracle-check`. The [conformance manifest](../../ocapn-conformance.md) records the supported profiles and deliberate deferrals.
