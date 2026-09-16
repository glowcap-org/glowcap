---
id: ADR-0173
status: accepted
date: 2026-09-16
tags: [loam, access, actors, persistence]
decision: "A managed method can return a runtime facet that admits every call through both its invoking grant and an exact stored target, and it can replace or remove local strong reference fields in the content transaction."
supersedes: []
superseded_by: []
amends: [ADR-0169, ADR-0172]
amended_by: []
---

# ADR-0173 Dependent returned capabilities and reference edits

## Context

ADR-0172 lets an application hand over the exact authority in a stored strong
edge. That is correct for a direct handoff, but it is too broad when a container
may reveal a related resource only under the container's current grant. The
stored target must also keep its own restrictions. Replacing content bytes
could preserve edges, but applications could not update or remove a declared
reference field in the same transaction.

## Decision

`ContentCall.discloseDependent(index)` returns a runtime facet built from the
invoking endpoint and the exact same-attachment capability held by strong edge
`index`. A call through the facet enters the ordinary retained-call queue. Its
working set loads the target endpoint and content at the same Store revision,
derives the target method's application requirement, and admits that
requirement through both the invoking grant and the target grant. The target
content runs only after both checks succeed.

The facet owns capability retains for both endpoints. It does not store a new
grant, expose either input capability, or reconstruct authority from an object
identifier. Nested dependent disclosures keep the original invoking endpoint
as their guard. An exact nested disclosure remains the separate direct handoff
defined by ADR-0172. Dependent facets are runtime authority, so durable content
stores their source capabilities and returns a fresh facet after reopen.

`ContentCall.replaceReference(index, capability)` replaces a committed strong
edge after `Attachment.capture` proves that the capability has a local durable
restoration recipe. `ContentCall.removeReference(index)` removes one. Indices
refer to the committed edge list for the whole callback, duplicate edits are
refused, and unchanged edges keep their order and strength. Payload and edge
changes produce one `Store.putCopying` participant. The retained call holds a
replacement capability until the write commits, aborts, or fails.

## Scope

This decision covers local strong fields within one attachment and Store.
Foreign and cross-vat fields need their own durable recipe. It does not add a
general multi-owner transaction, a new management grant, or durable identity
for a runtime dependent facet.

## Alternatives considered

- **Forward after checking only the invoking grant.** Rejected because it would
  bypass current restrictions on the held target.
- **Copy the target's object identifier into a new endpoint.** Rejected because
  an identifier is not capability authority and cannot prove the source role.
- **Mint a derived editable grant for every returned resource.** Rejected
  because the application asked for the conjunction of two existing
  authorities, not a third authority with an independent lifecycle.
- **Write payload and reference changes separately.** Rejected because a crash
  could install data that names custody the Store did not retain, or retain an
  edge the payload no longer declares.

## Consequences

A dependent call allocates a second bounded access operation while it is
pending. A live facet adds one Vat actor and two Host capability retains. The
facet and its target retire through the existing reply and actor boundaries;
failed local owning replies leave no dependent facet behind. Actor retirement
drains destructor-created sibling retirements before clearing the queue, and
Vat teardown treats root releases as terminal once it owns the complete actor
table.

The reference edit list uses the retained call's fixed arena. Replacement
custody uses the existing held-capability list, and the Store's ordinary write
outcome decides when the durable edge changes. Removing a field shifts later
indices only in the committed replacement record.

## Evidence and verification

`test/loam/access/hosting_wire_test.zig` covers nested exact and dependent
replies, separate invoking and target grants, ancestor pause and revocation,
and refusal to expose the original target or a controller. The in-process
hosting suite covers every composite reply arm, bounded failed-reply cleanup,
reference replacement and removal, weak and volatile refusal, and an aborted
write. `test/loam/lmdb/managed_hosting_test.zig` proves replacement, aborted
removal recovery, committed removal, and reopen. These run under
`zig build check` and `zig build loam-lmdb-test`.
