---
id: ADR-0153
status: accepted
date: 2026-09-14
tags: [access, resources, architecture]
decision: "managed access is an optional Zig application layer with a portable resource core; resource identity and scope remain independent of actor execution and protocol state."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0154, ADR-0155, ADR-0157, ADR-0158, ADR-0161]
---

# ADR-0153 managed access resource core

## Context

The [managed access architecture](../../planning/loam/access/architecture.md) separates reusable
resource authority from Rooms content and from glowcap's existing execution
machinery. A resource can outlive an actor or be presented through several
facets. Its identity cannot be a runtime export position, and its containment
cannot be inferred from a displayed path.

The first implementation needs structural invariants that later grant and
hosting behavior can reuse without importing Rooms or creating another Host.
They belong above the protocol and can be exercised without network execution.

## Decision

Expose `glowcap.loam.access.core` through `src/loam/access/`. The build gives `loam_access_core`
its own synchronous, no-I/O module at `src/loam/access/core/`, with no layer imports.
The `loam_access` module exports that core through the Loam facade. No protocol, actor, Host, or driver imports
managed access, and consumers that do not instantiate a graph incur no resource state.

The core graph owns resource IDs, kinds, and acyclic owned containment. A
resource ID includes the authority-store identity, slot, and generation. IDs
are comparison data; trusted structural mutation is not a callable capability
or an authorization API. Fresh stores require fresh owner identities.

Graphs reserve an explicit slot capacity with one allocation. Creation and
leaf destruction allocate nothing. Reparenting validates the entire affected
subtree before changing any edge, rejects cycles and excessive depth, and
updates descendant depths without a traversal allocation. Mutation requires
the current revision; failed operations preserve state and revision.

Slot reuse advances the generation. Generation exhaustion permanently retires
a slot, and revision exhaustion refuses mutations. Neither counter wraps.
Destroying a parent with children refuses rather than implicitly deleting them.

Scopes describe one object, a bounded canonical selection, or an owned subtree.
Subtrees include future descendants. A subtree cannot narrow an exact object
or finite selection merely because it currently has no other descendants.
Coverage and narrowing are evaluated against the current graph, and a graph
move requires re-evaluation before those results can inform authority.

## Current implementation boundary

The original slice supplies resource structure and scope evaluation to native
Zig consumers. [ADR-0154](ADR-0154-access-local-grant-lifecycle.md) extends it
with local grants and runtime policy algebra.
[ADR-0155](ADR-0155-access-prepared-grant-writes.md) adds graph reservations
and prepared grant writes. Persistent storage, actor integration,
C archives, and Rust bindings remain unimplemented. Rooms still uses its current application model and grant machinery.
The [implementation plan](../../planning/rooms/access-grants.md) owns their
replacement; this change introduces no compatibility adapter or fallback.

No wire behavior changes. The first model tests consume the graph and scopes;
application integration remains unimplemented. Resource IDs cannot be published
as access or substituted for Host capabilities.

## Alternatives

- Using actor IDs for resources ties content identity to runtime incarnation.
- Adding graph state to the Host charges every Host for an optional application
  concern and duplicates authority ownership.
- Flattening subtree scope to its current members loses continuing access to
  future descendants and permits incorrect narrowing decisions.
- Allocating while applying a move makes partial mutation possible on failure.
  Explicit capacity and prevalidation keep that transition infallible once it
  starts changing edges.

## Evidence

`test/loam/access/graph_test.zig` covers owner and generation separation, stale writes,
cycles, subtree depth, sibling maintenance, counter exhaustion, allocation
failure, and zero allocation after initialization. `test/loam/access/scope_test.zig`
covers exact versus continuing scope, reparenting, canonical selections,
foreign and stale resources, and destroyed-slot reuse.

`zig build test -Dtest-filter=access` runs those focused tests. The public API
compilation test and `zig build check` include the new namespace. The build
module graph and architecture check prevent dependencies on Host, actors,
protocol state, or I/O. Namespace and layer inventories name the new surface.

Boundary probes injected a Host import, a direct standard-library I/O import,
and an aliased I/O import into the managed access core. The architecture check rejects
all three. The direct-import probe exposed a gap in the earlier substring
check; standard-library member detection now handles these forms and has its
own tests. A scope probe that allowed a subtree to narrow an exact object was
rejected by the future-descendant test. All injected defects were removed.
