---
id: ADR-0040
status: accepted
date: 2026-10-19
tags: ["driver", "c-abi", "bindings", "observability", "rooms", "ocapnviz", "capability", "authority"]
decision: "Trace producers report the session identifier both peers derive and a hash of each observed message's wire bytes."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0040 Trace observation authority

## Context

Several peers can observe the same wire without routing their application traffic through one observer. Access to that observation must itself be explicitly granted.

## Decision

Trace producers report the session identifier both peers derive and a hash of each observed message's wire bytes. The convergence endpoint assigns namespaces and restamps time. The viewer decides how to combine sightings of one wire.

Live observation is a read-only CapTP capability. A browser enlivens it and grants an inbox for bounded canonical records. Telemetry ingestion remains a separate one-way adapter, and observation grants no endpoint control.

An enabled raw trace endpoint also requires the minted persisted trace secret at connection admission. The announced sturdyref carries the corresponding viewing grant. Reachability alone admits neither producers nor viewers.

## Alternatives and consequences

Routing direct-message traffic through a room would surrender the direct handoff property. Producer-selected namespaces could collide. Suppressing one end of a wire at ingestion would discard facts that only that producer sees. Unguarded WebSocket broadcast would make observation ambient authority.

Bounded ordering, slow-consumer handling and loss remain explicit contracts. Trace data is optional observation, not a failure journal or proof that an application effect committed.

## Evidence

Trace convergence, subscription, authentication and browser-view tests cover this path. [The diagnostics decision](ADR-0031-structured-diagnostics.md) owns failures with no return recipient.
