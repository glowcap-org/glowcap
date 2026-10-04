---
id: ADR-0137
status: accepted
date: 2026-08-26
tags: [rooms, sessions, capabilities, persistence, revocation]
decision: "A durable Rooms session owns a bounded grant ledger outside its workspace checkpoint, derives stable publication authority from its root entropy and client-minted grant IDs, and projects each facet's actual access with admin-only grant inventory."
supersedes: []
superseded_by: []
amends: [ADR-0134, ADR-0135]
amended_by: [ADR-0183]
---

# ADR-0137 Durable Rooms session grants

## Context

The durable session root can mint observe, interact, and admin facets. The
original facet operation returned a live reference and a live revoker. That is
useful for an OCapN handoff on an existing connection, but it does not give a
second browser an attenuated sturdyref that survives the session host
restarting.

Publishing those facets without durable state would create a worse contract.
An issued link would disappear on restart, or a revoked link could return if a
publication name were reused. Storing grants in the workspace checkpoint would
also give an interaction facet indirect control over session administration
and make a portable workspace export carry authority that belongs to its host.

## Decision

The session document store holds a separate grants document, spelled
`grants.json` by the file host. Each
row records a client-minted UUID, an exact human label, observe/interact/admin
rights, whether the holder may read history recorded before it arrived,
whether the grant is suspended and why, and whether the grant is revoked. The
ledger admits at most 32 active grants and 256 lifetime rows. Revoked rows
remain as tombstones, so an old identifier and sturdyref can never be reissued.

Issuance is idempotent by UUID. Repeating the same ID with the same label,
rights, and history answer returns the same grant. Reusing an ID for different intent is refused, as is reusing a
revoked ID. The client retains its operation ID after an ambiguous failure, so
a retry cannot mint a second authority. An administrator may later change what
a live grant carries (`setGrantPolicy`) without minting a new link: tier,
history, and suspension are ledger facts. A suspended grant answers its own
snapshot and keeps its watch so it can say why it has gone quiet.

The session derives each durable publication entropy with HMAC-SHA-256 over a
domain-separated grant ID, keyed by the durable session root's publication
entropy. The result is truncated to the Host's exported durable entropy length.
The derivation is a function of the id alone, so it is stable across restart
and across policy changes, unpredictable without the root secret, and disjoint
across grant IDs.

Issuance persists the row before publishing it. If publication fails, retry or
restart republishes the recorded intent under the same swiss number. Revocation
persists the tombstone before invalidating live references and removing the
Host publication. A publication cleanup failure cannot make the facet active
again.

The admin session snapshot carries the bounded active grant inventory and the
current facet's access level. Observe and interact snapshots carry their access
level with an empty grant inventory. Access is therefore a capability fact, not
a browser role inferred from which sturdyref field happened to be filled.

Attached views use that access fact directly. Observe facets paint a read-only
composer, receive no edit or moderation affordances from session events, and
cannot open session administration. Interact facets can mutate ordinary
workspace intent but cannot issue grants, replace checkpoints, inspect or
replace retained capability custody, or resolve pending effects. Admin facets
can issue, revoke, and change durable grants and manage retained operations and archive
capabilities through Settings.

Revoking a grant notifies its attached watchers with a terminal session-access
issue before releasing their observer capabilities. The revoked behavior also
checks the durable ledger on every call. Existing references fail immediately,
the sturdyref no longer enlivens, and restart republishes only active rows.

## Performance boundary

Grant persistence is an explicit administration act, not a message or wire hot
path. The complete ledger has fixed row and byte ceilings. Startup performs at
most one HMAC and one Host publication per active grant. Ordinary workspace
checkpoint writes do not read, copy, or rewrite the grant ledger.

Grant inventory rides the existing coalesced session snapshot and remains
bounded below the snapshot's aggregate text ceiling. Observe and interact
facets receive an empty inventory rather than a redacted row per grant.

## Consequences

The durable administration sturdyref is no longer the only restart-stable way
to attach. A user can issue separately revocable display, interaction, or
administration capabilities without copying the root.

An account capability may eventually retain or issue these sturdyrefs, but it
does not become an ambient owner of the session. The grant ledger remains
session administration, while workspace intent, browser presentation, and
archive contents keep their existing owners.
