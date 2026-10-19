---
id: ADR-0033
status: accepted
date: 2026-10-19
tags: ["relay", "browser", "transport", "websocket", "bindings", "tls", "c-abi", "rooms"]
decision: "The relay forwards bytes between explicitly admitted legs."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0033 Byte-transparent relays

## Context

Browsers and unreachable peers need a way to carry bytes without granting an intermediary CapTP authority or requiring it to understand the selected codec.

## Decision

The relay forwards bytes between explicitly admitted legs. It does not parse, validate or re-encode CapTP. End-to-end session identity and sealed-channel authentication stay with the peers.

Each runtime supplies its own byte-duplex carrier over the shared relay contract. Zig composes TCP, an injectable TLS stream engine and WebSocket framing. Managed runtimes own their WebSocket connector rather than receiving networking callbacks from the Zig driver.

One raw channel request makes one target dial. An application lifecycle may retry within its own bounded policy. The relay separately bounds endpoint runtimes and their creation rate.

## Alternatives and consequences

A CapTP proxy would acquire interpretation and routing responsibilities. One worker per WSS connection would impose stack and scheduler costs per peer. TLS inside the TCP type would mix socket lifetime with certificate policy.

Retries at both channel and application layers multiply work. A relay-wide negative target cache would let one request suppress another caller's valid attempt. Reachability failure is not a durable statement about peer identity or health.

A relay can still observe timing and volume, deny service or refuse a route. Confidentiality requires the peers' sealed channel. Rendezvous does not turn the relay into a capability intermediary.

## Evidence

Per-runtime relay contract tests, backpressure checks, TLS refusal cases and sealed rendezvous scenarios cover their respective boundaries. [Stability](../../stability.md) states the public-certificate and platform gaps.
