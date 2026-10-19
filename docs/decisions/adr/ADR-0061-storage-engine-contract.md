---
id: ADR-0061
status: accepted
date: 2026-10-19
tags: ["loam", "persistence", "storage", "lmdb", "c-abi", "sqlite", "bindings"]
decision: "A storage engine supplies transactions over get, ordered-prefix next, put and remove, with commit and abort for writes."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0061 Storage engine contract

## Context

A second disk engine should not require another implementation of read, commit, lookup and recovery policy. It must still report whether a failed write is known unchanged or may have committed.

## Decision

A storage engine supplies transactions over get, ordered-prefix next, put and remove, with commit and abort for writes. The shared core derives worker-facing operations from that contract once and checks native engines at compile time.

Each concrete engine owns its physical opening arguments, archive and operations guide. It projects the same lifecycle into C and Rust and runs the shared durable test suite. An embedding-supplied callback engine uses the same derivation.

A failed commit is reported as refused only when the library's actual source establishes that the write cannot have committed. Ambiguous outcomes stay recoverable. Every engine preserves the shared writer, revision, borrowed-row and completion-lifetime rules.

## Alternatives and consequences

Keeping the higher-level backend as the engine seam would copy transaction glue. A callback-only interface would remove native implementations and their direct tests. One tagged open call would make every archive know every optional engine.

The common contract supplies semantic parity, not identical physical costs or fault assumptions. Engine-specific maintenance remains explicitly owned rather than hidden behind a universal option structure.

## Evidence

`zig build loam-lmdb-test` and `zig build loam-sqlite-test` run shared durable behavior. Crash and I/O-fault probes establish their narrower boundaries, recorded in [stability](../../stability.md).
