---
id: ADR-0018
status: accepted
date: 2026-10-19
tags: ["net", "driver", "runtime", "resilience", "transport", "c-abi", "public-surface", "vocabulary"]
decision: "HostRuntime owns I/O for Zig Session and Server, the C driver and the bindings that use it."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0018 One Host I/O runtime

## Context

Different runtimes for blocking calls, stepped embeddings and scale measurements made fixes and memory claims apply to different product paths.

## Decision

HostRuntime owns I/O for Zig Session and Server, the C driver and the bindings that use it. The byte-fed Host remains the no-I/O embedding for callers that own their transport loop.

Stream transport completion backends join HostRuntime through the multiplexed resident contract. The resident owns its connection lifecycle, lends receive bytes from its pool and shares spare send storage. Idle stream wires hold no read or write buffer. Other multiplexed providers use the same runtime ownership boundary.

A blocking call drives this runtime until its wait settles. A stepped embedding gets the runtime's readiness contract. Neither adds a background thread to make a synchronous call appear nonblocking. Dial retry and shared runtime policy have one owner rather than a loop in every binding.

## Alternatives and consequences

Maintaining separate product and scale runtimes makes evidence easy to misapply. Putting a second completion Loop inside HostRuntime would create two lifecycle owners per wire. Copying pool reads into runtime scratch or keeping a spare buffer per idle wire would retain the cost pooling removes.

Locators are values. They do not retain providers or construct runtime resources. The embedding supplies transport packages and deployment state explicitly. The [stability guide](../../stability.md) owns platform and process evidence.

## Evidence

Runtime, provider, listener and binding tests exercise the shared path. `zig build test` covers its local contracts, while runtime and external checks cover their named processes. The recorded scale run and its limits are in [benchmarks](../../../bench/README.md).
