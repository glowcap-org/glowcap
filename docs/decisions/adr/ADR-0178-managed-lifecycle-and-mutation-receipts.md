---
id: ADR-0178
status: accepted
date: 2026-10-01
tags: [loam, access, persistence]
decision: "Resource indexes, independent management custody and exact mutation receipts share the existing owner transaction and hosting admission."
supersedes: []
superseded_by: []
amends: [ADR-0167, ADR-0168, ADR-0170]
amended_by: [ADR-0179, ADR-0180]
---

# ADR-0178 Managed lifecycle and mutation receipts

Resource moves, deletion and management mutations use the existing Store batch,
resource model and Host preparation. Separate write paths would let a content
effect commit without its authority or retry result. The shared transaction
keeps those effects together and leaves uncertain outcomes with the existing
recovery owner. Changed record contracts use the current prerelease format at
version 1; they provide no reader for earlier layouts.

## Resource structure

Resources retain a canonical parent and a sparse child-index root. The owner
retains the top-level child index. Creation updates identity lookup and child
membership atomically. Moves validate current ancestry, cycles and the deepest
descendant before staging either membership change. Descendants are streamed
through bounded depth frames rather than loaded as a resident graph. The scan
cost grows with the moved subtree; a leaf move does not scan unrelated resources.
The child-index identity lives in the resource row's strong edge. Decoding
validates the full edge shape, including the canonical parent's retention.
Creation and moves share one resource-row writer so payload and retention agree.

Leaf deletion removes child membership and persists a stable, inactive resource
identity. It preserves grant identities and independently retained application
content. Physical identity retirement remains separate work. Empty index paths
lose their retaining edges and become eligible for ordinary tracing collection.
The implementation adds no collector.

A native child cursor keeps a four-level index path and filters each candidate
through the held grant's current admission. It exposes authorized resource IDs,
which are names without authority. Its continuation stays private to the native
operation. An intervening commit requires fresh admission. Hosted observation
and transferable cursors remain separate contracts.
Iteration and preparation have exclusive custody of an operation's resource
bindings. A prepared structural change keeps its Read borrowed until close;
neither iteration nor closing the Read may release the leases it still uses.

## Management custody

Managed issuance returns separate use and control capabilities to the issuer.
Its source receipt retains both endpoints; the use endpoint has no edge to its
control. Recovery requires the issuing source and the original intent. The use
publication is installed with issuance. The control is retained through the
receipt and held-reference custody; publishing it is an explicit separate act.

An attenuated control retains its parent control and the same exact grant.
Creation checks Boolean powers and policy ceilings through the shared algebra.
Every management operation walks current control dependencies with one transient
lease and bounded depth. Powers remain immutable. Revoking a control disables
its management descendants while leaving the grant and use capability intact.
Grant edits still follow current grant ancestry. Paused use does not remove a
control's ability to resume its own grant; a revoked grant cannot regain access.
Inactive inspection reports status without policies or ancestor identities.
The owner stores an independent control revision. Descriptor attenuation and
revocation advance it without fabricating a grant event. Each new preparation
reads staged descriptors and dependencies; older preparations refuse after
any composed owner change. A Read that consumes proposals belongs to that exact
transaction and expires when staging ends, including abort or absent recovery.

## Exact mutation results

`RetryWindow` owns the sequence and eight-receipt floor shared by derivation and
other mutations. Each endpoint has separate derivation and mutation windows.
`derive` and `derive-managed` share the derivation sequence. Content and control
calls can use `mutate(sequence, method, arguments...)` for a recorded result.
Application methods declare read-only, idempotent or receipt-backed behavior.
A receipt-backed method refuses a direct call before invoking its effect.

A receipt binds its held source, dependent target where present, exact method
and arguments, and committed result. Capability leaves retain durable strong
edges. Current admission precedes replay; replay restores the saved result and
never invokes the mutation. Changed intent conflicts, future sequences refuse,
and expired sequences cannot become new requests. All holders of an endpoint
share its sequence domain. A no-op wrapped mutation still records its first
result; direct idempotent controls may return a later unchanged result.

Receipt encoding bounds nesting, payload and retained capability edges. Container
allocation failures and malformed decoding release partial ownership. Reply
capabilities must pass disclosure validation before receipt capture. Newly
allocated controls acquire routing custody before write submission and become
externally usable only after confirmed settlement.

## Evidence and cost

[Resource proofs](../../../test/loam/access/resource_cases.zig) run on volatile
storage and LMDB. Native tests cover reopen, scope changes, stale calls, filtered
children, rollback and lost replies. [Management proofs](../../../test/loam/access/management_cases.zig)
and [CapTP tests](../../../test/loam/access/management_test.zig) cover separate
custody, narrowing and independent revocation. [LMDB recovery](../../../test/loam/lmdb/management_test.zig)
restores exact issuer controls after both committed and absent uncertain writes.
The [process proof](../../../test/loam_managed_crash.zig) kills operations before
commit, after commit, after installation and before reply delivery.

The [native workload](../../../bench/loam/README.md) measures atomic use/control
issuance, management dependency walks, leaf moves, filtered child iteration and
receipt-backed edits. Existing call, cache and read budgets remain enforced.
These Linux proofs establish synchronous LMDB process-loss behavior. macOS
execution and the complete observation/terminal-retirement profile remain in
the completion queue; no hardware power-loss claim is made.
