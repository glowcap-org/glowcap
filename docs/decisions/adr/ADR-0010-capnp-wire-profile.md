---
id: ADR-0010
status: accepted
date: 2026-10-19
tags: ["codec", "capnp", "wire-profile", "zero-copy", "view", "performance"]
decision: "The Cap'n Proto codec implements its documented wire layout directly in Zig."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0010 Cap'n Proto wire profile

## Context

A second codec should reuse the protocol state machine while offering word-oriented data access. It should not add a mandatory schema compiler to a Zig consumer's build.

## Decision

The Cap'n Proto codec implements its documented wire layout directly in Zig. It emits and accepts the supported single-segment format, uses explicit endianness and aligned frames, and decodes into borrowed views.

A non-empty all-integer list can use its dedicated word-run encoding. It remains the same list in the semantic model. Empty runs are refused to avoid a second encoding for an empty list, and alignment is established before exposing a typed slice.

## Alternatives and consequences

A schema compiler would introduce another build tool and generated surface. An external codec library would add a dependency for this private profile. Owned-first decoding would require a second implementation for borrowed access.

The format is a glowcap profile. In-tree golden frames and cross-codec scenarios establish internal agreement, not interoperability with an outside Cap'n Proto implementation. Private wire negotiation carries the generated fingerprint.

## Evidence

`zig build test` and `zig build oracle-check` cover layouts, malformed word runs, traversal limits and live negotiated sessions. [Stability](../../stability.md) records the outside-reader gap.
