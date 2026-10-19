---
id: ADR-0021
status: accepted
date: 2026-10-19
tags: ["net", "netlayer", "iroh", "transport", "identity"]
decision: "The iroh transport uses a separate Rust sidecar behind a narrow C interface."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0021 Iroh transport sidecar

## Context

Authenticated discovery, QUIC, hole punching and relay reachability are substantial transport implementations. They should not become dependencies of the protocol core.

## Decision

The iroh transport uses a separate Rust sidecar behind a narrow C interface. Zig owns its resident/provider adapter. The endpoint owns the sidecar's runtime, identity and readiness resources, and callers explicitly retain or release them.

Nonblocking readiness lets many connections join the shared Host runtime. Discovery, relay configuration and durable identity remain transport concerns. CapTP sees the resulting authenticated channel and its actual provenance.

## Alternatives and consequences

Reimplementing QUIC and iroh in Zig would create a second large protocol project. A generated mobile-oriented FFI would expose more surface than the provider needs. Linking Rust into every core archive would impose Cargo and sidecar costs on consumers that do not use iroh.

The optional package isolates those costs and is replaceable behind its boundary. Endpoint shutdown must retire physical work before releasing callback contexts. A local reachability test does not establish behavior across two unrelated NATs.

## Evidence

The iroh sidecar and provider checks exercise real endpoints. [Stability](../../stability.md) and [community review](../../community-review.md) distinguish local transport checks, live Goblins adapters and unproven network conditions.
