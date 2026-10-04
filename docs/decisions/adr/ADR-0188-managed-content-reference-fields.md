---
id: ADR-0188
status: accepted
date: 2026-10-03
tags: [loam, bindings, ownership, rooms]
decision: "Project managed strong reference fields through shared Host preparation, protect the resource binding, and separate bounded application data codecs from retained authority."
supersedes: []
superseded_by: []
amends: [ADR-0182, ADR-0185]
amended_by: []
---

# ADR-0188 Managed content reference fields

## Context

A language consumer must author and restore exact held authority without
duplicating the shared reference engine. Empty content needs field insertion,
and content must retain the managed resource that admits its methods. Rooms
needs bounded data records paired with actual held capabilities, including
effect targets that survive replacement of current workspace custody.

## Decision

Shared Zig owns reference capture, save preparation and exact or dependent
disclosure. Managed methods append, replace and remove strong fields in the
same transaction as payload changes. Appends follow surviving committed
fields; edit indices continue to address the committed list. Schema capacity
refuses an append before capture or persistent staging.

C content declarations supply restoration and save requests synchronously.
URI bytes copy into the retained call arena. Shared preparation runs after
current grant admission and validates a foreign sturdy URI against the actual
held capability before invoking content. Rust uses ordinary Host `Ref` values
and the same C calls on LMDB and IndexedDB. It adds no reference state machine.
Dependent calls check both current invoking-grant requirements and the exact
saved target authority.

Preparation retains every declared save target before processing can wait.
Starting a Save retires the declaration retain after the operation takes its
own custody. Refusal, reset and cancellation release unstarted targets. Dropping
an application's last reference cannot invalidate a later queued declaration.

C resource creation reserves a first strong object edge to the shared resource
record. Application field indices omit this binding, and field edits cannot
replace it. Schema edge capacity includes it. Preexisting prerelease content
without the binding refuses invocation and requires explicit store recreation;
there is no compatibility reader or automatic reset.

Rooms owns the workspace, custody and effect payload codecs and one registry
for their schema family. Ordered fragments have page, count and aggregate byte
bounds. Payload coordinates encode role, slot and generation; decoders require
an exact match to separately restored typed fields. Coordinates never mint a
capability. Effect pages retain the original source, targets and committed
results independently of current workspace custody.

The production hosting owner must stage the complete page graph, strong fields
and resource binding atomically, subject to the Store's physical transaction
and recipe budgets. Codec payload bounds do not enlarge those budgets.

## Scope

The fixed-resource C/Rust/browser profile supports same-attachment capture and
foreign saves with an established sturdy URI. Cross-attachment local scope
registration, general graph editing, privileged owner lifecycle and application
management remain separate projections. Unsupported live references and
receipt capability kinds refuse rather than widening authority.

Rooms codec proofs and schema registration close the field/codec prerequisite.
Production session staging, startup, publication restoration, admission and
the editor remain in the combined application replacement. No session authority
ledger or runtime has been replaced by the codecs.

## Alternatives considered

- Saving an unrestricted parent and a client-side path can restore stronger
  authority. The field retains the exact held grant instead.
- Serializing capability IDs beside data creates another authority database.
  Hosting owns strong reference fields; data contains only checked coordinates.
- A separate Rust preparation loop duplicates Host ownership and recovery.
  Callbacks declare bounded work to the existing Zig owner.
- A single large application record exceeds the shared record budget.
  Ordered bounded pages preserve the existing storage contract.

## Evidence

Shared Zig tests prove append from empty custody and atomic refusal at schema
capacity. Existing reference scenarios prove foreign URI matching, missing
recipes and exact restoration. C tests inspect the protected resource edge.
The shared Rust/Chromium field trace exercises append, replacement, removal,
unsupported live saves, exact and dependent disclosure, refused edits and
cold restoration of the same grant.

Rooms portable proofs exercise fragment order/version, missing or mismatched
fields, full custody pages, aggregate capacity and original effect targets and
results. The Linux proof opens Loam with the complete schema family. These
proofs establish the codec contract, not production Rooms persistence.
