# Managed access implementation and acceptance

Status: active plan. This document names the evidence managed access must
provide at each integration surface. The [storage contract](storage.md) owns
durable records, trust boundaries, recovery and performance requirements.
The [completion queue](../completion.md#execution-order) owns the priority and
prerequisites of remaining native tasks; these acceptance groups do not form
a second task queue.

Groups 1–4 exercise access participation in the shared record, transaction,
backend and Host foundation. Preserve their implemented evidence and extend
it with each feature. Group 5 follows the native
[readiness checkpoint](../architecture.md#readiness-before-the-c-abi) and
extends the same contracts to Rooms. The [browser profile](../../../loam/browser.md)
records the implemented fixed-resource projection. Group 6 applies
throughout, not after integration. The
[Rooms plan](../../rooms/access-grants.md#ordered-implementation-and-exit-criteria)
owns application rollout.

## Current standing

Resource and grant views, common grant preparation, and bounded resource/grant/
event codecs are implemented in
[ADR-0166](../../../decisions/adr/ADR-0166-access-grant-records-and-plans.md).
The durable owner profile in
[ADR-0167](../../../decisions/adr/ADR-0167-managed-owner-storage.md) supplies
indexed record lookup, bounded access continuations, and transaction staging.
Native tests reopen that owner and recover revocation with matching content and
the latest event. Portable tests cover cache pressure, stale completions,
malformed paths, and cleanup. Durable native descriptors and operations now
restore use/control roles and current authority under ADR-0168. Fixed-resource
managed Host turns and ordinary publication restoration now use ADR-0169, with
native reopen and recovery evidence.
[ADR-0170](../../../decisions/adr/ADR-0170-durable-facet-derivation.md) supplies
reserved publication admission for fixed-resource derivation and eight retained
retry receipts per source endpoint, including native lost-reply/reopen evidence.
[ADR-0172](../../../decisions/adr/ADR-0172-explicit-disclosure-of-returned-capabilities.md)
supplies declared exact disclosure of stored reference fields, including nested
reply validation and native reopen evidence.
[ADR-0173](../../../decisions/adr/ADR-0173-dependent-returned-capabilities-and-reference-edits.md)
supplies dependent local facets, dual current-grant admission, and
transactional strong-field replacement and removal with abort and reopen
evidence.

Native general operation receipts, scoped retained events, sustained workloads
and process-loss proofs are recorded in the [shipped inventory](../../../shipped.md#resource-models).
The [first C/Rust lifecycle](../../../loam/c-and-rust.md)
adds consumer projection and ownership evidence, including bounded managed
children, editable policy and attenuated controls. Browser execution has
[Chromium lifecycle and ownership evidence](../../../loam/browser.md). Rooms still needs
its own applicable acceptance slices; Zig proof does not substitute for them.

## Implementation sequence and exit evidence

The groups below follow integration surfaces. Use the completion queue for
what to implement next and its deletion criteria; satisfy the applicable
groups in the same change. Existing evidence is a starting point, not proof
of a new method's failure or cost contract.

1. **Shared records and storage effects.** Bind the codecs and record-view
   misses to Loam leases, continuation ownership, and transaction batches. Adapt
   the current resident model to that view without a second evaluator. Run
   equivalent operations through resident and forced-miss views; inject stale
   rows, partial batches, malformed records, and quota failures. Include
   capability-valued content fields and scoped-query disclosure tests. A
   writer-custody test must suspend one owner, attempt another open, and prove
   that stale cached authority cannot serve after custody is transferred.
2. **Real atomic persistence.** Exercise the native adapter established by
   Loam and use the same scenarios in backend comparisons. Include application
   content participation, durable controls/publications, receipts, and events.
   Prove create/share/edit/pause/revoke and restore after process loss. Crash
   before and after every commit/publication boundary; lost acknowledgements
   and duplicate requests must recover the same authority. Round-trip a graph
   with original, limited-use, bounded-control, and foreign durable references;
   prove that field replacement and rollback update retention atomically.
3. **Bounded working sets.** Use Loam leases, coalesced bounded loads,
   revision-safe installation, and maintenance with managed access resumable
   preflight. Run the large-store workloads with a cache smaller than the
   dataset. Evict every relevant row between operations and prove ancestor
   revocation still holds.
4. **Existing Host integration.** Implement resource/control actors through
   Loam's publication and deferred-lookup support. Prove warm near calls, cold
   calls, durable restoration, disconnected callers, reply capability
   restrictions, and unrelated-actor progress during slow storage.
5. **Rooms adoption.** The fixed-resource IndexedDB consumer is proved.
   Consolidate authority-relevant
   content into its atomic owner store; remove superseded session-specific
   grants and independent commit paths in the owning integration slice. No
   automatic reset, prerelease format converter, or silently volatile fallback.
6. **Record evidence and publish supported limits.** Pin allocation budgets,
   fault-batch limits, turn-work budgets, and measured native/browser costs.
   Recovery, shutdown, backup, blob retention, and cleanup tests are required
   alongside throughput results. Promote only verified behavior into shipped
   documentation and retire the corresponding plan sections.

## Verification

This plan changes no runtime behavior. Its check is `zig build source-check`.
Implementation needs focused model and allocation tests plus `zig build check`.
Process crash and executor behavior add `zig build runtime-check`. Hosted and
browser integration use the existing Rooms proof fronts and outside-peer checks
identified in the [Rooms implementation plan](../../rooms/access-grants.md#verification-matrix).
The model fixtures are internal managed access authority tests, not CapTP
conformance evidence.
