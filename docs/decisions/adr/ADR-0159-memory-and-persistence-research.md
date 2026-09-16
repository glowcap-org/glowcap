---
id: ADR-0159
status: accepted
date: 2026-09-14
tags: [memory, persistence, access, research]
decision: "Place generic persistence below managed access, integrate sleepy actors with the existing Vat and Host, and select the physical backend through comparative experiments."
supersedes: []
superseded_by: []
amends: [ADR-0157]
amended_by: [ADR-0161, ADR-0165]
---

# ADR-0159 Memory and persistence research

## Context

The managed access storage plan selected SQLite before comparing native graph and memory
persistence designs. Resource access lifecycle is one consumer of those
mechanisms. Ordinary glowcap actors should be able to benefit from generic
persistence without acquiring the access module's resource and grant model.

The [research plan](../../planning/loam/research/memory-persistence.md) examines
embedded transactional stores, persistent regions, reference reconstruction,
and memory ownership together. It distinguishes persistent data, durable
capabilities, and recoverable execution, with primary sources and experiments.

## Decision

Reopen ADR-0157's unconditional first-native-backend choice. SQLite is a
transactional baseline; LMDB is a competing physical-store candidate. Test a
packed immutable-region layout separately from engine recovery, initially
using an existing engine for atomic root publication. A custom engine remains
an option if measured constraints justify its cost.

The managed access atomicity, current-authority, restoration, and bounded-memory contracts
remain requirements. Loam supplies optional generic persistence in glowcap. Its managed access extension
owns resource scope, grant algebra, lifecycle, and resource-specific records.
[ADR-0161](ADR-0161-loam-foundation-and-access-extension.md) owns module placement
and distribution.
Prove the shared API with a plain actor graph, non-actor records, and managed access
before freezing the ABI. Content, grant, and reference changes in one local
operation share one persistence transaction rather than independent commits.

Sleepy actors are required in the first durable actor integration. Held
references retain identity while eligible behavior state leaves RAM. Eventual
delivery activates cold targets through the existing executor and Vat queues.
Synchronous near calls require resident pinned targets or explicit acquisition;
they cannot hide disk I/O or replay effects. The
[sleepy-actor contract](../../planning/loam/actors.md)
owns activation, eviction, commit visibility, retention, and acceptance tests.

Inventory and reuse the existing Rooms session, grant, archive, filesystem,
and browser persistence mechanisms before extracting shared support. The
existing actor snapshots and immutable collections provide in-memory state
management, while Rooms already implements application durability. A new
generic integration must preserve those recovery and authority guarantees.

Reuse the existing Host, Vat, reference custody, promises, and embedding
executor. Persistent execution must specify durable acceptance and external
effects separately; graph snapshots do not establish either. No new scheduler
or protocol table is authorized by the choice of storage representation.

## Consequences and evidence

The next backend step is comparative implementation and recovery evidence,
not automatic adoption of SQLite or a bespoke mmap allocator. Native pointer
access is not a sandbox for arbitrary unsafe code; remote reference authority
continues to come through CapTP. Historical content snapshots cannot restore
historical grant authority for an ordinary managed call.

This decision accepts the research scope and decision criteria. It does not
claim that a new persistence substrate exists or outperforms the candidates.
The research plan owns the falsifiable hypotheses, experiments, and exit
criteria. Existing resource-view and codec work remains independently useful.
Documentation validation uses `zig build source-check`.
