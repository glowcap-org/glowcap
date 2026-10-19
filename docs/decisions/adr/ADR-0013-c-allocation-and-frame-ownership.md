---
id: ADR-0013
status: accepted
date: 2026-10-19
tags: ["c_abi", "memory", "performance", "api", "c-abi", "ownership", "bindings"]
decision: "A caller-owned context supplies allocation and free callbacks for a handle family."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0013 C allocation and frame ownership

## Context

A foreign caller needs control over allocation and lifetime without constructing a Zig allocator or guessing how an archive allocated a returned object.

## Decision

A caller-owned context supplies allocation and free callbacks for a handle family. Size and alignment are explicit. The context outlives the handles and frames that use it, and each allocation is released through its owning family.

Managed frame descriptors keep an owned frame in fixed opaque caller-owned words. Transferring a frame into that descriptor adds neither a descriptor allocation nor a byte copy. Releasing it destroys the inline owner and clears the descriptor.

## Alternatives and consequences

A Zig allocator vtable cannot be constructed portably by C. Per-handle allocation policy would leave nested frames and later buffers ambiguous. A realloc callback cannot promise preservation of every required alignment.

Caller-owned metadata removes a failure point after a successful dequeue or read. Its size and alignment are ABI facts, so native and Wasm layout generation must agree before a binding calls into an archive.

## Evidence

Allocator-failure tests, C layout checks and frame ownership tests run under `zig build test` and the generated-header checks. [The binding guide](../../../bindings/README.md) owns consumer setup and release conventions.
