---
id: ADR-0180
status: accepted
date: 2026-10-02
tags: [loam, access, retirement]
decision: "Owner-local weak identity inventories and resumable maintenance retire managed authority before shared tracing reclaims its payloads."
supersedes: []
superseded_by: []
amends: [ADR-0167, ADR-0178, ADR-0179]
amended_by: []
---

# ADR-0180 Bounded managed retirement

Managed cleanup needs to find an owner's descriptors, endpoints and publication
recipes. Grant and resource directories alone cannot do that. Scanning every
record exports cleanup cost to unrelated owners; making every issued descriptor
a strong owner root changes its ordinary lifetime.

An owner therefore maintains a sparse identity directory with weak leaf edges.
Descriptor and endpoint creation register in the caller's existing transaction.
Registration is part of those factories, rather than an embedding convention.
The inventory locates records without retaining them. Intermediate directory
pages use strong edges. Missing weak targets can be pruned by maintenance.
Observation contexts already have a bounded owner index and use its cancellation
contract for retirement.

The owner holds a persisted maintenance position. Each step loads and changes a
bounded working set, commits through Store, and can resume after process loss.
A step's expected sequence distinguishes a retry from permission to advance
again. Ordinary access still loads only its scoped authority and resource paths.
Maintenance never introduces another collector or holds a transaction across
storage or network delivery.

Owner retirement first closes admission, then retires observations and indexed
identities before removing grant, resource and event roots. Normal operations
refuse while retirement is in progress. The trusted owner administration surface
can continue maintenance; a held use or grant control cannot manufacture owner
administration authority. Retirement uses the Attachment publication barrier
and its commit/uncertainty recovery path, including cold names.

Terminal cleanup compacts descriptors and endpoints into explicitly dead record
shapes, drops their payload and dependency edges, and preserves irreversible
identity and retry refusal. A surviving dependent cannot become an independent
root when an ancestor is compacted. Active publications remain roots until their
explicit retirement. Strong stored dependencies and native retains continue to
protect records that their holders need; maintenance does not claim their last
release on behalf of a remote peer.

Grant and resource slot allocation floors survive directory pruning. An empty
live directory does not reset its high-water mark. Loam object identities and
durable publication names are never reassigned. Retired name reservations retain
58 logical bytes each before backend overhead. Tracing owns physical collection
of disconnected pages and expired payloads; native maintenance owns logical
retirement and pruning.

[Native tests](../../../test/loam/access/maintenance_test.zig),
[LMDB tests](../../../test/loam/lmdb/maintenance_test.zig) and the
[managed process proof](../../../test/loam_managed_crash.zig) cover interrupted
steps, pending work, cold names, retained references and owner retirement.
Both hosted receipt windows refuse expired sequences and retired results after
collection and cold reopen while their issuer remains live. Repeated
create/share/revoke/delete cycles bound logical records and payload bytes while
allocation floors grow. The [native workload](../../../bench/loam/README.md)
separates retained terminal records and name reservations from reclaimed payload.
