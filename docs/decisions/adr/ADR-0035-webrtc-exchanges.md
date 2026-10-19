---
id: ADR-0035
status: accepted
date: 2026-10-19
tags: ["transport", "webrtc", "browser", "signaling", "sidecar", "handoff", "net", "c_abi"]
decision: "The host owning a WebRTC peer drives its dial and accept exchanges."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0035 WebRTC exchange ownership

## Context

A DataChannel needs offers, answers and ICE candidates. Peer identity alone cannot route concurrent signaling exchanges, and a session signing key does not establish the durable identity authorized by signaling.

## Decision

The host owning a WebRTC peer drives its dial and accept exchanges. The native C provider owns its Rust peer, the Zig backend owns its signaling exchange, and the browser owns its RTCPeerConnection. The application supplies the signaling carrier.

Every exchange has an independent identifier. Candidate routing names that exchange rather than only a peer. Managed acceptance is the dial's mirror: authorize the offered remote designator, create the channel, send the answer and yield an accepted session.

The authorized remote key is fixed before CapTP starts. The hello must attest the corresponding identity before authenticated transport provenance is reported. Concurrent and crossed exchanges remain independent until CapTP applies its crossed-hellos rule.

Failure and cancellation retire peers and subscriptions. Closing a listener retires pending exchanges and untaken sessions. Native callbacks execute on the driver-owning thread. A signaling direction not supplied by a provider remains unavailable.

## Alternatives and consequences

Bring-up in every binding would repeat authorization and cleanup. One Zig exchange for browser and native I/O would require abstractions over descriptors and wake channels the browser does not have. Candidate routing by peer would collide, and choosing a winner during signaling would preempt CapTP's authority.

Raw adoption remains available to an application that explicitly owns bring-up. Signaling authorization and cleanup do not establish universal browser connectivity.

## Evidence

Native exchange and provider tests cover independent ids, acceptance and cleanup. Browser journeys cover the browser implementation. [Stability](../../stability.md) names recurring and on-demand WebRTC checks.
