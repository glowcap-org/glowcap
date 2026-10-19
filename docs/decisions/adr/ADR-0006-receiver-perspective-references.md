---
id: ADR-0006
status: accepted
date: 2026-10-19
tags: ["codec", "syrup", "wire", "references", "goblins-parity", "session", "taste"]
decision: "Decoding relabels reference descriptors into receiver perspective using only the wire tag."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0006 Receiver-perspective references

## Context

A wire descriptor describes the sender's relationship to an object. The receiver must validate the corresponding relationship against its own state without giving the decoder authority over session tables.

## Decision

Decoding relabels reference descriptors into receiver perspective using only the wire tag. The session then validates the result against its own tables. Encoding performs the inverse projection.

A slot describes its minting side and binding state. The wire descriptor is derived from those facts rather than stored as a second identity. A routed Host identity remains distinct from a session's wire position.

## Alternatives and consequences

Leaving perspective unresolved would require every consumer to repeat the flip. Consulting tables inside the codec would violate its stateless contract. Storing four independently interpreted reference kinds would multiply resolution, GC and handoff cases.

The representation admits only meaningful states. Slot ownership and incarnation checks remain session concerns, while codecs parse and render the selected descriptor.

## Evidence

Reference projection, validation and round-trip scenarios run under `zig build test` and `zig build oracle-check`. The model, session and engine remain separate [compiler-enforced layers](ADR-0011-compiler-enforced-layers.md).
