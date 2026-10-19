---
id: ADR-0063
status: accepted
date: 2026-10-19
tags: ["model", "codec", "session", "performance", "engine", "actors", "driver", "memory"]
decision: "One bounded region in the owned frame head stores argument views, Struct entries and integer words."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0063 Frame-owned argument views

## Context

Materializing every incoming value repeats parsing and copies containers a handler may never read. Unbounded view storage or an unmetered fallback would turn that optimization into memory or traversal amplification.

## Decision

One bounded region in the owned frame head stores argument views, Struct entries and integer words. Decoding validates while filling that region. When storage fills, a validated wire-backed representation retains the same traversal bounds.

Wide rare records remain lazy views over their framed bytes. Integer runs remain list backings. An owned source, parsed view and wire-backed sequence all represent the same semantic values.

Actor deliveries borrow views for the turn. Host handlers use one accessor contract over those views or transactionally lifted application values when references are present. Host applications never receive raw wire positions as capability identities.

A reply without capabilities can remain a view until its retained answer copy. Capability-bearing replies still use transactional lowering. Frame lifetime bounds every borrow.

## Alternatives and consequences

Counting the entire tree first would add another scan. A separate buffer would add an allocation, while an uncapped region permits amplification. Metering only stored views would leave overflowed subtrees unbounded. Lazy per-access capability lifting would need another retirement mechanism for unobserved occurrences.

A per-peer retained frame block did not improve the recorded allocator workload and added idle state, so frames are released at their owner boundary. This is a workload-specific result, not a claim about every allocator.

## Evidence

Codec slab, traversal, integer-run, Host accessor and borrowed-reply tests run under `zig build test` and `zig build oracle-check`. [The benchmark guide](../../../bench/README.md) owns the instruction and allocation measurements.
