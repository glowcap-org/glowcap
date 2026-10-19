---
id: ADR-0022
status: accepted
date: 2026-10-19
tags: ["architecture", "build", "c-abi", "packaging", "netlayer", "transport", "bindings", "actors"]
decision: "The C ABI ships symbol-disjoint archives for the protocol core, byte-fed Host, optional driver and concrete providers."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0022 Composable C archives

## Context

An embedding may need the protocol core, an owning driver, or only one transport. A single umbrella library would make optional runtimes mandatory dependencies.

## Decision

The C ABI ships symbol-disjoint archives for the protocol core, byte-fed Host, optional driver and concrete providers. Each family has an explicit header and ownership contract. The shared Host projects capability identity and routing once, while a binding supplies its language's values, application behavior and runtime adapters.

An embedding that owns I/O can feed the Host and drain data actions. The driver adds transport execution as a separately linked choice. No private Zig implementation archive is promoted into an extra public C contract solely to share internal code.

## Alternatives and consequences

An umbrella archive obscures dependency and lifetime ownership. Reimplementing Host orchestration per binding duplicates protocol policy. A callback-heavy core serve loop would invert control and make reentrancy every embedding's problem.

Adding a provider does not require teaching the generic driver its concrete protocol. Static and shared packages must still prove that their advertised composition links and exposes the intended symbols.

## Evidence

Header generation, symbol inventories, archive fingerprints, binding consumers and extracted-package C smoke tests cover this boundary. [Packaging](../../../bindings/PACKAGING.md) owns the release procedure and publication order.
