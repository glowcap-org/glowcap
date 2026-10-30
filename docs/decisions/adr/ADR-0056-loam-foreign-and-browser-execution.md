---
id: ADR-0056
status: accepted
date: 2026-10-19
tags: ["loam", "bindings", "ownership", "storage", "browser", "authority", "hosting", "rooms"]
decision: "Optional C archives project the shared Loam lifecycle into the existing Host."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0056 Loam foreign and browser execution

## Context

A storage miss or abandoned future must not release memory while an engine or IndexedDB transaction still uses it. Foreign languages also must not reconstruct policy or transaction semantics.

## Decision

Optional C archives project the shared Loam lifecycle into the existing Host. Zig owns permission evaluation, transaction preparation and recovery. Rust and browser adapters supply storage effects through that shared lifecycle.

Fixed startup slots retain admitted operations until physical retirement. Dropping an observer is not proof that a worker stopped. Shared callback contexts and borrowed buffers remain alive until the effect actually retires.

IndexedDB executes the same transaction through bounded transaction-local key/value callbacks. Evaluation does not suspend across arbitrary asynchronous work inside an active transaction. An exclusive Web Lock provides browser writer custody.

Management calls receive held controls rather than caller-supplied resource keys as authorization. Content codecs carry bounded application data and checked coordinates. Strong reference fields belong to hosting and retain the exact authority selected by shared preparation.

## Alternatives and consequences

A binding policy engine would diverge from Zig. Per-effect heap owners add a failure point to every miss. Loading the complete store defeats bounded residency. Releasing callbacks when a future disappears can leave live work using freed storage.

The shipped consumer profile establishes fixed-resource lifecycle and the explicitly projected management operations. It does not imply that every graph edit, collection cursor or privileged owner operation is available through a typed foreign client.

## Evidence

C, Rust, LMDB and Chromium/IndexedDB consumer proofs exercise their real effect boundaries. [C and Rust integration](../../loam/c-and-rust.md) and [the roadmap](../../roadmap.md) own the current API and planned widening.
