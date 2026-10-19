---
id: ADR-0016
status: accepted
date: 2026-10-19
tags: ["actors", "ocap", "vat", "bindings", "session", "engine", "node"]
decision: "A behavior can forward its answer through the existing vow and settlement machinery."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0016 Capability forwarding

## Context

A wrapper should be able to attenuate or forward a far capability without forcing the caller to understand a second promise layer or requiring a new interposition framework.

## Decision

A behavior can forward its answer through the existing vow and settlement machinery. The partner sees one answer that settles once. Caretakers and attenuators compose this primitive with their own application policy.

A promise introduced to another session is a local promise export backed by that session's inbound answer. Settlement goes through the same guaranteed settlement path as ordinary answers. Under pressure the answer retains its outcome and queues its carrier when capacity returns.

Listener claims and retained gifts follow that projection's lifetime. An unheld projection can be collected, and a moot settlement releases its own escrow rather than rooting the projection indefinitely.

## Alternatives and consequences

Returning a promise as a resolved value exposes an extra promise layer. A second import/listener/retry table would create competing settlement authorities. A general message-interposition framework would add policy the forwarding primitive does not need.

Forwarding preserves the exact target and its authority. It does not turn an identifier into a capability or bypass a mediated source's admission.

## Evidence

Actor forwarding, relayed promise, listener and pressure scenarios run under `zig build test` and `zig build oracle-check`.
