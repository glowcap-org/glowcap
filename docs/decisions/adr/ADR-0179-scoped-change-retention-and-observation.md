---
id: ADR-0179
status: accepted
date: 2026-10-02
tags: [loam, access, observation]
decision: "Bounded committed change batches and context-bound opaque cursors supply scoped observation through the existing Store and Host."
supersedes: []
superseded_by: []
amends: [ADR-0167, ADR-0178]
amended_by: [ADR-0180]
---

# ADR-0179 Scoped change retention and observation

Observers need ordered committed changes, restart recovery and an explicit
response when retained history expires. Filtering raw owner events is not
enough, because a cursor that advances for hidden activity or exposes an owner
revision discloses facts outside the held authority.

## Committed change history

An owner retains at most 32 change batches. One batch describes one owner in
one Store transaction and contains at most 16 effects. Several preparations
compose into that batch. Grant, resource, content and independent control
changes use the same history writer. Abort and unchanged mutations retain no
new batch. Store completion and recovery govern visibility.

Each effect names its affected branch for scoped filtering. Paths are bounded
to 65 identities, including the target. Persistent managed owner depths are
therefore at most 64. Retention drops the oldest batch edge. Ordinary tracing
owns collection. Events retain metadata needed for replay, never a database
snapshot or a remote delivery transaction.

Grant authority, lifecycle and inventory stamps are distinct. Each stamp pairs
its revision with the corresponding committed batch position. Child issuance changes its
ancestors' inventory without changing their use authority stamp. Resource
placement, subtree and content stamps are likewise distinct. A child-index
rewrite does not perturb a use facet's access cursor. Ancestor inventory and
subtree updates cost bounded path writes, rather than an owner-wide scan.

## Scoped cursors and disclosure

An observation context binds an exact held descriptor and, for use, one target
resource. Its persisted unpredictable key seals cursor positions and a digest
of the authorized dependencies. Cursors cannot be transferred between contexts
or interpreted as authority. The embedding supplies entropy through the same
boundary used for durable publication.

A use observer receives effective-access and target-change notices. A control
observer receives changes within its granted inventory and its own management
availability. Ancestor effects become scoped notices. Replies disclose no raw
owner revisions, positions, ancestor identities or hidden sibling activity.
Current authority is checked before every delivery, including after reads and
while use is paused. Terminal revocation carries status alone.

A context also persists its registration boundary. Fresh cursors and cursors
continued from a previous reply use scoped positions, never the current owner
tail. AES-128-SIV seals 40 bytes of position and digest into a 56-byte cursor,
using the context identity as associated data and a 32-byte key.

A cursor advances only for changes visible to its context. If unrelated
activity evicts its old history, an unchanged dependency digest preserves the
cursor. If visible changes have expired, the result explicitly requests
resynchronization and supplies the current authorized snapshot with its cursor.
The digest includes monotonic stamps, so a visible change followed by its
reversal cannot silently become an unchanged cursor.

Replay is bounded and ordered. Delivery may coalesce retained batches with the
current scoped snapshot. Loss or delay never preserves invocation authority.
Ordinary protected calls still evaluate current grants and resource placement.

## Hosted custody

Hosted registration uses the endpoint's exact mutation receipt. A lost reply
recovers the same observation context. Reconnect reuses that context and its
cursor. Context quotas bound retained state. Inactive contexts are removed by
explicit cancellation.

A subscription supplies separate receive and cancel references. An eventual
receive can wait in the existing preparation lane without preventing its
canceller from running in another ordered actor lane. Existing Attachment
reads, Vat turns, CapTP settlement and publication retirement execute all
effects. Managed observation introduces no Host, scheduler or event loop.

Cancellation closes the context, releases its source retention and retires its
publication through the shared transaction and retirement fence. Submitted
reads retain their buffers until exact completion. Native users drive the same
bounded observation operations and own their storage executor.

## Evidence obligations

[Native proofs](../../../test/loam/access/observation_test.zig),
[Engine proofs](../../../test/loam/engines/observation_test.zig),
[CapTP proofs](../../../test/loam/access/observation_hosted_test.zig) and the
[managed process-loss proof](../../../test/loam_managed_crash.zig) cover live
delivery, replay, overflow, slow receivers, cancellation, ancestor revocation,
hidden activity, abort and unchanged effects. A maximum-depth scenario calibrates
warm preparation. A maximum-fanout scenario declares storage, ingress and
transport budgets. The [usage guide](../../loam/access.md#observing-held-access)
owns the API and costs. The [workload report](../../../bench/loam/README.md)
measures native context retention, replay fanout and cancellation. Hosted parked
call memory and terminal reclamation remain separate measurement obligations.
