---
id: ADR-0156
status: accepted
date: 2026-09-14
tags: [access, grants, capabilities]
decision: "Native use and control references convey grant authority directly and share the ledger's prepared mutation path."
supersedes: []
superseded_by: []
amends: [ADR-0154, ADR-0155]
amended_by: [ADR-0157, ADR-0168]
---

# ADR-0156 managed access native grant capabilities

## Context

A grant's capability reference both designates the grant and conveys authority
to exercise it. The holder needs no additional credential. The ledger's
internal `GrantId` locates its record. Hosting associates that record with the
capability being invoked. These are implementation representations of the same
model, not two authorization systems.

The [local ledger](ADR-0154-access-local-grant-lifecycle.md) already owns access
evaluation. Its [prepared writes](ADR-0155-access-prepared-grant-writes.md) own
validation and commit. Native callers need references that select one grant
and express use and management as distinct powers without rebuilding either
mechanism in an application or binding.

## Decision

Expose opaque `GrantUse` and `GrantControl` types through `glowcap.loam.access.core`.
The trusted ledger owner creates them using `createUse` and
`createControlCopying`. Owning the ledger already gives full model authority.
These factories confer selected authority on their recipients. Neither opaque
reference exposes a ledger getter, an arbitrary-grant constructor, or a way to
convert use authority into management authority.

A held use reference checks its bound grant with `require`. The application
supplies the target's operation requirements and committed facts. Managed access checks
current scope, policy, lifecycle, and ancestors using the existing evaluator.
This synchronous check produces no reusable admission for a later content
operation. The complete content transaction still needs an admission bound to
its effect and revisions.

A use reference can prepare a child grant through `prepareDeriveCopying` if its
current grant permits delegation. The ledger enforces current ancestry and
issuance ceilings. Completion remains an owner/storage operation. Only a
committed grant can acquire a use or control reference. The proposed ID in a
write view cannot publish the staged grant. Reference allocation happens after
commit in this primitive. An allocation failure leaves the committed grant
available for an owner retry. Full atomic issuance and publication must reserve
publication capacity before committing and retain operation receipts.

A control's `prepareCopying` accepts an edit without a grant selector. Its
bound grant is always the target. Policy editing requires a retained management
ceiling. Pause, resume, and revoke are separately granted booleans, defaulting
off. A policy edit must fit both the control's management ceiling and the
grant's immutable issuance ceiling. The owner validates a control's ceiling
against that issuance ceiling when creating the control.

Management possession is independent of the use grant's temporary pause. A
resume control must remain usable to resume the grant. An ancestor's pause
still blocks effective use. Changing the child's own status cannot clear it.
A control can configure terms within its ceiling while an ancestor restricts
use, but those configured terms never bypass the current ancestor intersection.
Revocation remains terminal through the common ledger path.

All accepted changes enter the existing prepared-write implementation. There
is no additional policy evaluator, transaction engine, credential lookup,
runtime, global registry, or I/O dependency. Commit continues to return the
same owned change event. A failed or unchanged request returns no event.

## Ownership and cost

Each created reference object allocates once through the ledger allocator.
A control additionally copies a selected management scope so later caller
mutation or release cannot alter its authority. The ledger's `max_capabilities`
limit bounds live objects. Retained aliases share an object and increment a
checked reference count without allocating. Final release frees the object and
its copied scope, returning that quota slot. Release changes native custody.
It does not pause or revoke the grant or another held capability.

The graph and ledger stay at stable addresses while referenced. Ledger
destruction refuses while any capability object or prepared write remains.
Calls and reference ownership are serialized with the ledger. These are native
Zig pointers with normal native memory-safety obligations. Opaque types prevent
ordinary construction and accidental role mixing. They are not a sandbox
against hostile native code casting or corrupting memory.

## Integration boundaries

These native primitives have test callers only. They do not host resource
methods, export CapTP objects, serialize handles, or publish locators. The
hosting adapter will retain the appropriate native reference in each actor's
behavior. Possession of the actual actor reference supplies call authority. It
must not ask the caller for another grant credential. Use and control exports
remain distinct. The existing Host and Vat provide dispatch and reference
transfer.

The [owner
plan](../../loam/access-architecture.md#atomic-content-and-access-changes) still
owns combined graph/content/access transactions, original resource capabilities,
publication receipts, restoration, and retained upstream capabilities. Control
attenuation, persistent control lifecycle, inventory inspection, scoped
subscriptions, and remote retries are not implemented by these native objects.
Rooms uses its existing session facets until the application integration lands.

## Evidence

`test/loam/access/grant_capability_test.zig` exercises possession without additional
credentials, one selected grant despite other available records, independent
use/control roles, exact management targets, separate lifecycle powers,
policy and constraint ceilings, ancestor enforcement, private prepared grants,
uncertain storage fences, and terminal revocation.

`test/loam/access/grant_capability_memory_test.zig` exercises copied control scopes,
quota recovery, retained aliases, busy destruction, release during a prepared
edit, and every allocation failure in reference creation. Management-ceiling
bypass and wrong-grant control-target injections each failed their focused
test and were removed. These are native model tests. They establish
no CapTP dispatch or persistent storage behavior.
