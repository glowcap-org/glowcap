---
id: ADR-0176
status: accepted
date: 2026-09-26
tags: [loam, captp, ownership]
decision: "Resolve cold durable publications through bounded Host admission and an atomic Loam name index, using existing Session answer custody."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0176 On-demand durable publication discovery

## Context

A restarted Host must answer stored publication names without enumerating the
store or creating one actor endpoint per publication. Fetch can arrive while a
record is cold, a retirement commits, or the requester releases its answer.
The first principles require one authority for protocol answers, bounded
residency, exact target identity, and a portable core without I/O.

The pinned [CapTP fetch contract](<../../../conformance/ocapn-spec/upstream/draft-specifications/CapTP Specification.md#fetch-method>)
returns an object or an error through ordinary delivery. It requires no
synchronous response. Storage latency therefore needs no new wire operation.

## Decision

The engine's composition seam receives one fetch context containing the secret
name, a Session-stamped answer target, and the session-local bootstrap fallback.
It returns `found`, `missing`, `deferred`, or `refused`. The engine owns immediate
settlement. The Host owns publication precedence and bounded provider admission;
a hidden registry reservation cannot fall through to storage. Deferred replies
use the existing answer settlement queue, including its resolver, listener,
pipeline, and detached-answer custody. Codecs and session semantics are unchanged.

Loam registers one opt-in provider for a Host's durable namespace. Its fixed
name and fetch capacities coalesce identical cold requests before emitting
lookup work. The embedding performs storage work and returns ticketed results.
The attachment loads the descriptor through its existing Store cache and read
lane, rechecks current publication authority, and restores the exact endpoint
through the ordinary restoration path. Fetch leaves no permanent publication
registry row. Submitted work retains its Host lease after callers cancel;
unregister refuses until the provider's authoritative work storage is idle.

A schema can declare one immutable 128-bit name at a fixed payload offset.
Shared transaction validation installs a schema-scoped name-to-object index
atomically with the record in both volatile storage and LMDB. Names cannot be
changed or assigned to a different object. Collection reclaims the descriptor
but preserves its index reservation, preventing a retired name from retargeting.
Lookup validates store, incarnation, and revision; stale completions retry
against current metadata. An uncertain write fails discovery closed until
recovery. Recovery of an absent retirement restores prior discovery without
creating a registry row for a previously cold publication. The proven outcome
settles the write before any fallible restoration. Existing bounded retirement
slots retain restoration custody through allocation refusal, cold read completion
and later transactions. Ordinary attachment advancement retries restoration only
while the Store is idle and after call settlement releases leases. The manual
`applyRetirement` API is removed; retirement commits through the attachment
write lane that owns its admission fence.

## Alternatives considered

- Startup enumeration makes memory and startup work grow with publication count.
- A Loam-specific engine hook moves persistence policy below its owning layer.
- A second cache or read lane duplicates activation and completion ownership.
- Separate immediate and deferred name callbacks repeat the registry lookup and
  obscure the distinction between an absent name and a hidden reservation.
- Removing index rows with collected descriptors permits old names to retarget.

## Costs and compatibility

Discovery allocates its owner and two bounded arrays at registration. Admission
copies only the 16-byte name into a group; fetch waiters retain no frame bytes.
Each completed fetch uses existing endpoint/projection and answer queue costs.
The Host adds one provider pointer; standalone engine/session footprints do not
increase. Each persistent name reserves 25 key bytes and 33 object-ID bytes,
before backend overhead, even after descriptor collection. Future compaction
must preserve these identity reservations.

Loam metadata format 2 requires the index. Format 1 stores are rejected and must
be recreated; there is no migration scan or partial-compatibility reader. This
is independent of the LMDB disk-format version.

## Evidence and gate

`test/loam/hosting/discovery_test.zig` exercises coalescing, cancellation,
pressure, missing/corrupt records, retirement recovery, large cold populations,
pipelining in both profiles, virtual answers, and answer-position reuse.
`test/loam/access/sharing_test.zig` overlaps discovery with a managed call's
publication read. Shared named-record scenarios run against volatile storage and
LMDB. `loam-actors-crash-test` reopens a killed process and fetches without an
explicit descriptor restore. `check`, `runtime-check`, and `check-external`
exercise the owning contracts and protocol conformance.

## Scope

One provider serves one Host durable namespace. Foreign stored capabilities,
managed owner retirement, index-reservation compaction, and browser persistence
remain separate work. Pending fetches and calls are not durable messages.
