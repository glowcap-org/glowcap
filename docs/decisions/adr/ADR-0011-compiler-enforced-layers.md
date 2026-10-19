---
id: ADR-0011
status: accepted
date: 2026-10-19
tags: ["architecture", "build", "modules", "layering", "naming", "codec", "vocabulary", "driver"]
decision: "Each source layer is an internal Zig build module with explicit one-way imports."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0011 Compiler-enforced layers

## Context

Folder names and review conventions cannot prevent a protocol layer from importing I/O or reaching through a sibling codec.

## Decision

Each source layer is an internal Zig build module with explicit one-way imports. Model, codec, session and engine live under the OCapN namespace. Each codec is a sibling module over shared contracts, and their registry is the owner that imports both.

The public root curates the application namespace. Actors add local execution, the Host owns multi-session capability identity, and HostRuntime owns I/O. A connection names a framed byte channel, while a session names a CapTP relationship. Runtime residents own transport execution state.

## Alternatives and consequences

Content scans alone cannot express the import graph reliably. An extra adapters directory would add a folder without strengthening the existing contract. Vocabulary based on obsolete implementation tiers makes ownership harder to see.

Module boundaries constrain dependencies, not archive packaging or application architecture. The C archives are separately composed. Current names and layer responsibilities belong in the [architecture guide](../../architecture.md), rather than a succession of naming records.

## Evidence

The compiler rejects missing import edges. `zig build source-check` holds the remaining content and naming rules, and `zig build test` exercises the public module surface.
