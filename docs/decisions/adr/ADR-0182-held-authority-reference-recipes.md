---
id: ADR-0182
status: accepted
date: 2026-10-02
tags: [loam, persistence, capabilities, ownership]
decision: "Save exact held authority through checked local dependencies or established sturdy references, prepare restoration through ordinary Store and Host work, and retain forwarded results at their producer."
supersedes: []
superseded_by: []
amends: [ADR-0102, ADR-0162, ADR-0163, ADR-0172, ADR-0173, ADR-0177]
amended_by: [ADR-0188, ADR-0203, ADR-0204, ADR-0205]
---

# ADR-0182 Held authority and reference recipes

## Decision

An ordinary local field keeps its direct strong object edge and lazy restoration.
A recipe field has a typed edge to a bounded restoration record. The portable
graph follows both kinds of strong edge and interprets neither recipe nor
capability. Hosting owns recipe interpretation and retains a recipe before
loading it or waiting for another participant.

Local recipes identify another attachment's restoration owner and retain its
target through a strong edge in the same Store. The embedding registers stable
attachment names in one bounded scope over that Store and Host. Registration
order can differ after restart. A missing owner parks bounded restoration work.
It does not fall back to another attachment's behavior. Attachments on one Host
share its Vat. Another Host owns another Vat and uses the foreign recipe path,
including peers running in the same process.

A foreign recipe stores a canonical, already established sturdy URI. Saving
enlivens that URI through Host and compares the resulting canonical capability
with the capability held by the caller. A URI naming some other grant or role
fails before content staging. The remote publication owner preserves the target
independently of the caller's Store. Removing a field releases local recipe and
runtime custody. It does not retire a publication other holders use. No
distributed transaction changes that remote publication.

Managed methods declare which fields and replacements need preparation. Current
grant admission precedes restoration work. After any Store revision change,
preparation is retired at a top-level Host boundary and rebuilt before
invocation. Ordinary local methods need no network work. Recipe creation, field
replacement and payload changes stage in the same Store transaction.

Exact disclosure returns the saved authority. Dependent disclosure retains a
facet that checks the invoking grant before dispatch. Its application behavior
declares a requirement for each forwarded method. The separately held target
performs its own authority check through its normal delivery path.
A forwarded effect dispatches once. Later Store changes do not replay it.

Host's owned call result attaches its observer and reserves answer retirement
before the send commits. One bounded buffer copies the callback-borrowed result
and retains nested capabilities through projection. It uses the existing vow,
value lifting and cancellation owners and leaves the application FIFO alone.
Native local eventual calls retain their existing data-only resolver contract.
Capability results use the Host Value delivery boundary.
Deferred local Value replies release newly created export names after their
listeners acquire canonical retains, unless a listener publishes a wire
occurrence. Foreign route and promise projection owners remain unchanged.
Wire Value replies use the existing outbound occurrence leases, so nested
foreign authority can transfer through ordinary Node handoff staging.

## Supported profile and consequences

Owned Host capability arguments survive preparation and session loss. Local
targets can be captured directly. Foreign replacements need a completed save or
a method declaration supplying their sturdy URI. Receipt intent and result
codecs still support same-attachment durable capabilities. Unsupported receipt
capability kinds refuse before any content write. General unresolved promises,
operating-system handles and live-only capabilities have no durable field
representation.

Record envelope version 2 adds one boolean per edge to select restoration kind.
Commit metadata version 3 refuses old stores at opening. No compatibility reader
is added. A recipe has at most one local dependency and 4097 payload bytes. Call
arenas, save quotas and existing read lanes bound its pending memory. Foreign
restoration pays Host's existing dial and enliven costs. The exact current
evidence belongs in the Loam guide and stability records.