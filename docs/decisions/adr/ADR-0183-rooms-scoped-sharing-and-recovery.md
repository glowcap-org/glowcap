---
id: ADR-0183
status: accepted
date: 2026-10-03
tags: [rooms, authority, content, persistence, interaction]
decision: "Rooms uses exact held authority or source-dependent managed facets, separate offers and continuing access, and shared Loam transactions for content, grants and recovery."
supersedes: []
superseded_by: []
amends: [ADR-0137, ADR-0139]
amended_by: []
---

# ADR-0183 Rooms scoped sharing and recovery

## Context

Session grants use a session-specific policy tier and JSON ledger. Room seats
use fixed observer/participant admissions with separate facilities and role
publications. Recursive content sharing needs one scope and lifecycle contract
across those surfaces, including capabilities returned from a restricted view.
Giving a limited recipient a broad reusable room link for reconnect defeats
the offered restriction. Moving content between collections can also change
its audience without changing any message reference.

OCapN carries capabilities and does not define Rooms permissions, invitations or
verified recipient identities. This decision keeps application authority above
the protocol and preserves the portable synchronous core. The native managed
endpoint, dependency, receipt and disclosure mechanisms at `src/loam/access/`
provide the shared foundation. Rust supplies Rooms requirement declarations as a
consumer, not a Zig semantic oracle.

## Decision

Rooms supports direct sharing of the exact held reference and separately managed
equal or narrower facets. A managed facet retains its source dependency,
immutable ceiling and explicit scope. Its returned content/file/line views
retain that dependency unless an independent handoff is explicitly authorized.
Cross-owner mediation holds and invokes the upstream capabilities. Saved foreign
authority follows ADR-0182 and cannot be reconstructed from IDs or names.

An offer, an accepted grant and a live seat are separate objects. Offers choose
single/reusable admissions and one-visit/continuing access independently. Claim
commits the exact result and bounded retry record before publication or reply.
Continuing recipients save their exact accepted endpoint and join with it.
They do not obtain a stronger public entrance. Closing an offer stops future
claims, while revoking its source branch also withdraws admitted dependent
access. Public offers intentionally issue independent one-visit admissions.
Replacing a public offer affects unused entrances, not existing accepted seats.

Grant management uses separate scoped controls with enumerated powers and
policy ceilings. Presets replace explicit disjoint field groups and save
values, not a mutable role-name dependency. History, source, scope, lifetime,
delegation quotas and status remain independent controls. Configured and
effective access remain distinct. Public defaults and complete operation
requirements are owned by the Rooms contract, not inferred from current tiers.

Owned containment is acyclic and local to one authority owner. Message identity
and authored context survive same-owner reorganization. Placement and branch
provenance are separate records. Moving content requires source/destination
authority and explicit management of audience changes. Structural and content
effects commit with managed access stamps in one bounded transaction. Larger
atomic selections refuse rather than expose a partial result.
Cross-owner placement uses separately acknowledged insertion and removal of
the exact retained capability. Ownership transfer is not supplied by this act.

Rooms declares application content/admission schemas and typed requirements.
The shared Loam model owns grants, ceilings, ancestry, receipts, restoration
and terminal retirement. Existing Host/Vat and embedding executors realize
effects. There is no additional access engine or scheduler. Application schema
version 1 replaces unreleased formats without a compatibility reader.

## Amendments

ADR-0137 uses persist-before-publication, stable reference identity, idempotent
issuance, exact lost-reply recovery, current per-call enforcement and status-only
suspension. Shared records, exact endpoint publications and typed grouped
permissions govern session grants. Owner/service quotas charge their bounded
retirement.

ADR-0139 keeps room identity separate from discovery, explicit seat custody,
receipt competition, generation-sensitive entrances, and the distinction
between moderation and management. Fixed membership kinds become preset
expansions. Offers can be persistent and accepted access can permit limited
rejoin. Seats remain live. Public offer changes preserve independent admissions.
Moderator removal still ends a seat. Grant policy changes require a separately
held control. ADR-0142's authenticated/one-use name continuity and archive
reconciliation remain, with current grant checks at recovery boundaries.

## Scope (what this does not decide)

Shared Rooms integration, C/Rust projection and browser Loam storage execution
are not implemented by this decision. Native readiness, including macOS
acceptance, remains a prerequisite. No new CapTP message, codec profile,
identity registry or transport privilege is introduced. Timed grant expiry,
cross-owner ownership transfer, distributed authority transactions and
centrally editable role definitions are outside the contract.

## Alternatives Considered

- **Extend each existing ledger and role mechanism:** rejected because session,
  archive and room paths would own different revocation and recovery semantics.
- **Recover limited access through broad reusable entrances:** rejected because
  reconnect could exceed the accepted terms and escape revocation dependency.
- **Make all shares managed:** rejected because forwarding an already held
  reference is ordinary capability delegation with its existing boundary.
- **Treat collection placement as authority inheritance:** rejected because a
  foreign reference, provenance link or shared process does not supply rights.
- **Apply preset names dynamically:** rejected because editing a convenience
  bundle could expand previously issued authority without an authorized edit.

## Consequences

The Rooms work on the [roadmap](../../roadmap.md) owns permission keys, method
requirements, derived references and retirement ownership (operation authority),
preset groups, public defaults and management/recipient interaction (access
editor), schemas, transaction boundaries and acceptance budgets (storage and
budgets), every consumer family, recovery route and mechanism removed by each
implementation slice (consumers to replace), and content identity and audience
(content model).

## Evidence and gate

Design walkthroughs exercise the five opening
use cases through issuance, use, change, delegation, reconnect and revocation.
They and the operation inventory are reviewable design acceptance, not executed
Rooms proofs. `zig build source-check` validates this documentation change.
Native shared mechanisms have separate Zig scenarios and recorded measurements.
The remaining implementation phases require application, runtime, browser,
pressure and outside-peer proofs before claiming shipped behavior.
