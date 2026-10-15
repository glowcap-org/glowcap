---
id: ADR-0154
status: accepted
date: 2026-09-14
tags: [access, grants, architecture]
decision: "managed access owns runtime policy algebra and local grant lifecycle. Applications declare operation meanings without reimplementing grant mutation or ancestor enforcement."
supersedes: []
superseded_by: []
amends: [ADR-0153]
amended_by: [ADR-0155, ADR-0156]
---

# ADR-0154 managed access local grant lifecycle

## Context

Resource structure and scope are implemented under
[ADR-0153](ADR-0153-access-resource-core.md). Editable managed access also needs
an immutable issuance ceiling, current configured terms, and a dependency on
the authority that issued it. Those decisions must live in the shared Zig
model before any actor adapter or language binding exposes them.

An application should declare what an operation needs. It should not coordinate
ancestor traversal, revocation propagation, or permission intersection itself.
The [managed access architecture](../../loam/access-architecture.md) assigns those
algorithms to managed access and content facts to the application.

## Decision

Add `Policy`, `Terms`, `GrantId`, and `GrantLedger` to `glowcap.loam.access.core`.
They import no runtime and introduce no actor, Host, driver, or scheduler.
These initial APIs are trusted model operations. Grant IDs select data. They
are not use capabilities, control capabilities, or authorization credentials.

### Runtime policy algebra

Each ledger copies one immutable schema descriptor. Stable keys declare up to
64 Boolean permissions and 16 unsigned constraint fields with lower-bound or
upper-bound operators. Keys must be unique and sorted within each namespace.
A schema identity fixes the keys, their order, and their meaning. Reusing an
identity for a changed descriptor is invalid embedding behavior.

Policy values bind their compact representation to that schema identity.
Unknown keys, unused permission bits, undeclared bounds, and duplicate request
keys refuse. Absence of a bound means unrestricted. Intersection keeps common
permissions, the larger lower bound, and the smaller upper bound. Narrowing
cannot remove a parent constraint. All these algorithms execute in Zig.

Application requirements name the permissions and committed facts relevant to
one effect. For example, a history check supplies the message's creation
sequence to a declared lower-bound field. An upload operation supplies its
size to an upper-bound field. The application must include every relevant
requirement. Omitting a content fact does not prove that content unrestricted.
The initial model has no fact-relation hooks, alternatives, or projections.
Unsupported semantics must be implemented in the shared vocabulary before a
binding can expose them.

### Grants and mutation

A ledger borrows one graph at a stable address. The embedding serializes their
use. Mutations check both graph and ledger revisions before evaluating or
changing state. This detects stale proposals but does not yet provide atomic
content/access transactions or durable operation receipts.

Trusted owner issuance creates an independent root. Child issuance names an
existing local grant and can only narrow every current ancestor's configured
terms and immutable ceiling. The child records that bounded ceiling forever.
Its delegation allowance is strictly smaller than its parent's. Total depth,
child count, and retained record count have explicit limits. Parent links
are immutable and always point to an earlier record, so issuance cannot cycle.

Editing changes configured terms within the recorded ceiling. It preserves
local pause status. Effective use intersects the ceiling and configured terms
of every ancestor against the current graph. A later parent expansion cannot
enlarge a child's ceiling, and a parent restriction applies without rewriting
any child. Separate grant paths never implicitly combine their permissions.

Pause is temporary. Revocation is terminal for the branch, including descendants
whose own records remain active or paused. Effective status gives revocation
precedence over pause. Resume and edit refuse a revoked dependency. Independent
roots and sibling branches remain unaffected. Revocation works even after the
scope's resource is gone, and repeats on the same revoked record are idempotent.

Grant slots are retained, including tombstones and their child counts. They
are never reused. Generation checks reject another incarnation. A fresh empty
ledger with a previously used owner identity is not restoration. This prevents
old IDs from silently selecting newly issued authority. Capacity exhaustion
refuses issuance, and revision exhaustion refuses state changes without wrap.

### Ownership and cost

Initialization allocates the configured record capacity. Terms copy policy
values inline. Exact and subtree scopes need no further allocation. Selected
scopes copy at most the scope module's bounded selection size. Issuance copies
both ceiling and configured selections. Editing copies the replacement before
releasing the old selection. Inputs may therefore borrow a current record.
Every potentially failing allocation finishes before a mutation commits.

Reads, ancestry checks, and lifecycle changes allocate nothing. Their work is
bounded by grant depth, graph depth, selection size, and schema limits. Revoking
a branch updates one record. These are model cost bounds, not throughput or
network performance measurements.

### Committed change events

Every successful mutation returns an owned `GrantLedger.Change` with its
committed graph/ledger revision, grant identity, and change kind. Issuance
includes the optional parent inventory. Policy and status changes identify
the affected branch without enumerating descendants. Status events include
the local before/after states. They borrow no grant or policy memory.

Unchanged edits and lifecycle requests return no event and keep the revision.
Failed mutations return an error without a change. An event is produced only
after the state it describes has committed. The model does not own an event
loop or queue, and event delivery never replaces current authority checks.

The [observation contract](../../loam/access-architecture.md#observable-access-changes)
requires the access module's actor integration to expose scoped change subscriptions over
CapTP. Delivery, retention, replay, and transaction events for resource moves
remain unimplemented. Raw model events must not expose hidden authority
relationships to remote observers.

## CapTP and application integration

The intended use and management surfaces are capabilities callable across
CapTP. The resource owner enforces the selected grant on every protected act.
A separately held control capability authorizes remote edits. Passing a facet
preserves its exact grant dependency across copies. Neither serialization of
an ID nor receipt of an access description creates stronger access.

The hosting layer must bind calls to owner-issued authority and enforce each
controller's management ceiling before invoking the trusted model. The access module's
owner transaction layer must coordinate graph, grant, and opaque content
changes. Applications declare their content effects and execute selected
storage effects. They must not reproduce grant algorithms or coordinate
independent commits themselves.

[ADR-0155](ADR-0155-access-prepared-grant-writes.md) adds prepared grant writes
and exact storage completion. The complete owner and hosting layers remain
unimplemented. The ledger has only original and local-parent sources, with no retained upstream
capability representation. Cross-owner enforcement remains an explicit hosted
dependency in the plan. A local ID cannot substitute for it. No CapTP messages,
wire schemas, persistent formats, C ABI, or Rust bindings change here. Rooms
continues to use its existing grant machinery.

The [roadmap](../../roadmap.md) tracks the remaining work. This
record advances the local grant boundary of ADR-0153 and leaves its resource
identity and containment decisions unchanged.

## Evidence

`test/loam/access/policy_test.zig` fixes bound direction, runtime schema validation,
full-width masks, and intersection laws over a finite set of values. Injected
permission union and reversed lower-bound intersection fail those laws.
The test does not establish application requirement mappings.

The grant tests cover issuance ceilings, ancestor edits, initial and inherited
pause, terminal revocation, independent paths, reparenting, destroyed-resource
generations, delegation quotas, stale revisions, and counter exhaustion.
Injected skipped ancestor evaluation and ignored ancestor revocation fail
their corresponding lifecycle scenarios.

Event tests cover commit ordering, exact revision stamps, branch effects,
owned event lifetime, and no event for unchanged or refused operations.
Suppressing a committed policy event fails its event scenario.

Allocation-failure testing covers every allocation in initialization, root and
child issuance, and editing. It checks unchanged revisions and record counts,
retained policy, parent child counts, and leak-free unwind. A failing allocator
also verifies that exact-scope grants and lifecycle operations need no allocation
after graph and ledger initialization. The selected-scope tests exercise caller
mutation, replacement from borrowed records, and stale later selection entries.

`zig build test -Dtest-filter=access` runs the model tests. `zig build check`
includes them, public API compilation, and the existing architecture boundaries.
