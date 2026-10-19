---
id: ADR-0024
status: accepted
date: 2026-10-19
tags: ["c-abi", "bindings", "netlayer", "driver", "iroh", "webrtc", "archives", "build"]
decision: "The generic C driver begins with no transports and accepts explicitly registered provider packages."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0024 Transport providers and archive contracts

## Context

Separately loaded archives can outlive an application handle, retain callbacks or disagree about a struct layout. The boundary must fail before incompatible code is called.

## Decision

The generic C driver begins with no transports and accepts explicitly registered provider packages. Provider leases own callback context lifetime until all admitted work has physically retired. Locators contain no provider retain.

Each archive exposes a fingerprint derived from reflected function types, public constants and canonical public-struct manifests. Binding layout expectations are generated from those same manifests. Loaders compare family identity before ordinary calls.

Libc-linked shared archives pin themselves resident when loaded. The pinned Zig standard library can detach worker threads whose final exit still executes archive code after an owner releases its resources. An embedding's close therefore cannot safely imply that this code can be unmapped immediately.

## Alternatives and consequences

A driver aware of every transport would expand with each optional dependency. A second manifest in each binding would duplicate ABI facts. A process-global diagnostic or provider authority would be duplicated by separately compiled archives.

Per-owner pin calls would scatter an artifact-wide requirement across constructors. Residency prevents unloading, not logical resource cleanup. Hosts, endpoints and provider leases must still close correctly. Removing residency requires evidence that all relevant worker exits are joined.

## Evidence

Generated-header checks, layout and family-fingerprint tests, provider lifecycle tests and packaged C consumers cover the boundary. [Bindings](../../../bindings/README.md) lists consumer checks.
