---
id: ADR-0029
status: accepted
date: 2026-10-19
tags: ["bindings", "c-abi", "dial", "netlayer", "layer-separation"]
decision: "A byte-fed embedding can request a dial plan and interpret its host/port, peer identity, signaling or rendezvous result."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0029 Dial and accept plans

## Context

The same locator can be consumed by the Zig driver or an embedding that owns its channel. Both need one interpretation of grammar and peer requirements without moving I/O into the core.

## Decision

A byte-fed embedding can request a dial plan and interpret its host/port, peer identity, signaling or rendezvous result. The embedding opens the channel. Bindings using the generic driver instead pass a typed locator to a registered transport package, which owns concrete I/O.

Accept admission receives the provider's declared designator scheme and listener facts. The Host derives, retains and signs its locator, preserving an explicitly published peer snapshot. Zig provider dispatch also resolves through the shared admission path.

## Alternatives and consequences

A registry in every binding would copy locator policy. Calling a resolver and then re-dispatching independently would leave a second authority. Exposing a concrete socket type would make a transport-neutral plan unusable for non-socket providers.

A plan is data, not an authenticated connection or a provider lifetime. The selected channel must still prove the requirements the Host records before session authority is installed.

## Evidence

Dial-plan, accept-locator, provider dispatch and byte-fed Host scenarios run under `zig build test`. Binding consumers exercise the generic driver boundary.
