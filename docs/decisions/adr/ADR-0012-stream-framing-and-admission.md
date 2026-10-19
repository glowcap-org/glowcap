---
id: ADR-0012
status: accepted
date: 2026-10-19
tags: ["codec", "runtime", "net", "framing", "resilience", "c_abi", "memory", "performance"]
decision: "A byte stream wraps each bare codec frame in one canonical Syrup byte string: decimal byte length, a colon and the exact frame bytes."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0012 Stream framing and admission

## Context

A transport boundary, a codec grammar and a session admission decision answer different questions. Repeatedly scanning a partial stream with a codec duplicated work and missed the production framing contract.

## Decision

A byte stream wraps each bare codec frame in one canonical Syrup byte string: decimal byte length, a colon and the exact frame bytes. Message-preserving transports and whole-frame APIs carry the bare frame.

The envelope or transport delimits one body. The engine copies the admitted frame behind its owned head, and the session parses it through one entry point. The negotiated codec must accept the entire body as exactly one message. No codec independently frames a production stream.

Small fixed read buffers use bounded owned spill for a larger admissible frame. Drained storage follows the consumer's explicit retention rule rather than growing every idle connection to the largest frame it has seen.

## Alternatives and consequences

Concatenated bare codec frames disagree with the Goblins stream wire. Wrapping message-preserving transports adds no boundary information. Trusting the outer length alone would admit malformed or trailing codec bytes. Keeping an unused scanner would retain another untested production path.

Limits apply before untrusted lengths can drive unbounded retention. Framing grants no authority and does not replace session validation.

## Evidence

Framing, spill, ingress-limit and malformed-body tests run under `zig build test`. `zig build goblins-interop` checks the shared stream form against a live peer.
