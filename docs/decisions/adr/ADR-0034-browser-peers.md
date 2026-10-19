---
id: ADR-0034
status: accepted
date: 2026-10-19
tags: ["bindings", "transport", "wasm", "browser", "peer", "relay", "rendezvous", "handoff"]
decision: "The browser runs the same byte-fed Host compiled to WebAssembly."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0034 Browser peers

## Context

A browser can open a channel but cannot expose an ordinary listening socket. That reachability restriction should not force its capabilities or protocol state into a server-side proxy.

## Decision

The browser runs the same byte-fed Host compiled to WebAssembly. It can host objects, answer calls, pass capabilities and take part in handoff over its established sessions.

Replies travel on the caller's session through an explicitly held reply capability. They do not assume that the caller can be dialed back. A browser that must be cold-dialed uses an identity-bound relay rendezvous or another supported channel establishment mechanism.

Browser I/O, rendering and signaling stay outside Wasm. WebRTC can establish a direct DataChannel where its network and signaling conditions permit it. A byte relay carries sessions without becoming a CapTP peer on their behalf.

## Alternatives and consequences

A TypeScript protocol implementation would duplicate codecs and session semantics. A server bridge would make the browser a client of another peer. Dial-back replies would fail for other non-listening participants.

Running the common core establishes protocol reuse, not internet reachability. Browser APIs, network conditions, certificates and deployment configuration still determine which channel can be established.

## Evidence

Wasm layout and handshake tests, browser-peer scenarios and production-page checks exercise the shared core. [Stability](../../stability.md) records which direct and relay paths have recurring or on-demand coverage.
