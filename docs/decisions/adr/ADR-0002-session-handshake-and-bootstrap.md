---
id: ADR-0002
status: accepted
date: 2026-10-19
tags: ["handshake", "bootstrap", "lifecycle", "substrate", "start-session"]
decision: "The core owns the no-I/O handshake and bootstrap state machines."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0002 Session handshake and bootstrap

## Context

Every embedding needs the same authenticated session transition and bootstrap lookup. Putting their orchestration in each transport would create several protocol implementations.

## Decision

The core owns the no-I/O handshake and bootstrap state machines. A negotiating session accepts the hello and abort, validates the exchange, then opens with its bootstrap export installed. An adapter supplies entropy, transports the frames and drives completion.

Bootstrap fetch construction and outcome matching belong to the engine. The session owns its publication registry and validates state. The engine synthesizes replies, while the application supplies the published targets. Parsing a message never invokes application code or invents transport authority.

## Alternatives and consequences

Opening without exchanging the actual hello would bypass the protocol's admission point. Generating entropy in the core would break deterministic scenarios and browser compilation. A combined fetch-and-network call would force the engine to own an event loop.

The division makes the same transition usable from an in-process scenario, a byte-fed Host and the Zig runtime. It does not make a self-signed session claim proof of durable peer identity.

## Evidence

Handshake, refusal and bootstrap scenarios run under `zig build test` and `zig build oracle-check`. The [community checks](../../community-review.md) describe the live Goblins evidence.
