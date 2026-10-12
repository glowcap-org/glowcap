---
id: ADR-0205
status: accepted
date: 2026-10-05
tags: [loam, hosting, capabilities, lifetime]
decision: "A declared dependent live save prepares one facet over actual source and target capabilities, saves that facet once, and verifies its guarded pair on settlement retry."
supersedes: []
superseded_by: []
amends: [ADR-0173, ADR-0182, ADR-0204]
amended_by: []
---

# ADR-0205 Stable dependent live results

## Context

A posted line must remain governed by its originating session grant and its
own upstream authority. Saving the raw line and disclosing it exactly loses
the session dependency. Constructing a dependent facet on every disclosure
changes its identity on receipt replay. Private settlement also needs to
recognize a retry carrying the original upstream result.

## Decision

`save_live_dependent` declares a managed source endpoint and exact held target.
Shared preparation constructs the existing dependent endpoint and reserves its
live custody before any preparation wait. The callback can borrow only the facet
from its matching declaration, then stage that facet as a live field. Borrowing
it grants no reply disclosure.

The committed recipe restores the same retained facet throughout the hosting
lifetime. Exact disclosure of that field preserves replay identity. Every
call through the facet enters ordinary shared dependent admission: current
source authority and current target authority both govern the operation.
Applications declare the supported forwarded methods through their existing
dependent requirements.

Attachment locality does not imply a common authority owner. When a held local
target belongs to another owner, hosting uses ordinary forwarding even if both
endpoints live in one attachment. Source admission uses the source content's
dependent requirement. The target performs its own admission. The shared local
evaluator remains available within one authority domain. Owner selection
precedes decoding local actions. Forwarding a sequenced mutation preserves its
verb, sequence and arguments for the target's own receipt. The source does not
consume that sequence.

Each scope reservation carries the guarded pair alongside its facet. These
capability names borrow the facet's two retains. Matching requires the source
actor and exact target capability. Resource IDs, policy equality and result
coordinates cannot substitute. On a committed settlement retry, the application
restores its saved facet, checks this pair against the incoming source and
target, and reuses the facet. It does not construct another one.

The reservation, unknown-write recovery, collection and lifetime-close rules
are those of ADR-0204. No runtime handle enters storage. Cold restoration
refuses. Stable identity is a property of the current live custody only.
C and Rust project declarations, callback borrowing and pair matching without
adding authority state outside shared hosting.

## Consequences

Preparation pays the existing dependent actor and two authority retains, one
temporary canonical target spine, and the ordinary live reservation spine.
The fixed reservation inventory adds an optional pair of capability names.
Reference sizing includes both spines. Replay and pair matching construct no
facet and acquire no additional authority.

This complements fresh dependent disclosure for durable source fields. It
provides no durable identity for a live facet and no stronger recovery route.
Source revocation cannot recall an effect already dispatched.
