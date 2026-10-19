---
id: ADR-0019
status: accepted
date: 2026-10-19
tags: ["net", "driver", "transport", "architecture", "netlayer", "testing", "completion-loop", "dialer"]
decision: "Completion backends own shared read-buffer pools."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0019 Pooled completion I/O

## Context

At high connection counts, a fixed buffer retained by every idle socket can cost more than protocol state. Transport dispatch also has to accept runtime-selected and userspace providers.

## Decision

Completion backends own shared read-buffer pools. A receive lends a bounded view, and the consumer returns that buffer exactly once. Pool exhaustion delays receiving rather than closing a healthy connection.

Accepted and dialed sockets share one connection lifecycle. Platform backends own their kernel operations, while transport residents own addressing and provider resources. An in-process byte transport exercises this contract without sockets.

A resident reports held completions through an explicit pending-work query. Holding records does not require keeping its descriptor artificially readable. The runtime services pending records before sleeping and preserves a usable readiness signal for stepped embeddings.

## Alternatives and consequences

A per-connection read buffer makes idle memory grow with the connection count. A pool above the backend cannot model kernel-selected buffers without another ownership translation. One thread per connection does not meet the intended density.

The same ownership contract supports different platform mechanisms and sidecar readiness. It does not make io_uring, epoll, kqueue or a Rust executor identical in cost. Native stream and intrinsically message-framed transports keep their distinct framing rules.

## Evidence

Buffer recycling, pool exhaustion, accepted/dialed teardown and resident readiness tests run under `zig build test`. [Benchmark procedures](../../../bench/README.md) attribute transport and protocol costs separately.
