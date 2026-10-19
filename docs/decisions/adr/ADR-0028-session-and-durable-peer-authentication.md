---
id: ADR-0028
status: accepted
date: 2026-10-19
tags: ["net", "driver", "engine", "identity", "captp", "host", "bindings", "handshake"]
decision: "Every CapTP session uses a fresh signing key."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0028 Session and durable peer authentication

## Context

A hello proves possession of a session signing key. A locator is a claim by that signer. Neither fact alone proves that a cleartext connection reached a particular durable peer.

## Decision

Every CapTP session uses a fresh signing key. A connection can separately supply authenticated-channel provenance for the durable identity it actually proved. A dial target is a requirement, not evidence.

A peer owns its complete advertised locator snapshots. Every hello signs the selected snapshot, and handoff uses the exporter's signed claim. Hints contain routing and profile advice rather than a second session credential.

Identity reporting distinguishes verified session signer, signed locator claim and durable authentication provenance. Incomplete or unverified handshakes refuse identity access. A key-shaped designator or transport name cannot mint proof.

## Alternatives and consequences

Reusing a durable key as every session key would blur reconnect incarnations. Reporting one verified Boolean would let callers confuse distinct claims. A hint credential would duplicate channel authentication and still fail to authenticate a cleartext pipe.

Pinning is enforced before subsequent traffic in the same input chunk can apply. Sealed channels and authenticated providers supply their own real proof. Cleartext TCP remains assertion-only where explicitly permitted. Onion addressing has its separate documented identity boundary.

## Evidence

Handshake refusal, identity provenance, selected-peer and mixed-transport tests run under `zig build test`. [The stability guide](../../stability.md) identifies channels that provide no peer authentication.
