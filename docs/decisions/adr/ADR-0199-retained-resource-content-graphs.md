---
id: ADR-0199
status: accepted
date: 2026-10-04
tags: [loam, hosting, bindings]
decision: "Prepare resource-owned content pages through a bounded read window and replace them within the existing managed transaction, with page links separate from capability fields."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0199 Retained resource content graphs

## Context

Managed content can exceed one record and the resident cache. Its pages and
saved capabilities must commit together with the resource event and retry
receipt.

## Decision

A graph registration declares the admitted schemas and aggregate page, payload
and edge limits. Shared hosting prepares it before invocation and stages
replacements in the existing Store transaction.

The root's first strong object edge binds the canonical resource. Its remaining
edges select owned pages. Each page has the same binding followed by its saved
capability fields. Preparation validates schema, binding, link role and page
uniqueness. It never traverses a capability field as an application page.
Callback-scoped handles select prepared pages. Object names cannot select rows
to read or replace. Kept pages retain their identity, and written pages receive
fresh identities in the transaction.

Cold preparation copies one page into the bounded retained call arena and
releases its lease before reading another. The root's strong closure supplies
collection custody. Saved reference preparation also releases each recipe
lease after restoring its held authority. Store revision and incarnation
fences restart preparation when another transaction intervenes.

Physical pages produce one logical managed content event. A refusal during
staging aborts the whole transaction, including the receipt. An indeterminate
write remains behind existing Store recovery. Graph registration does not
promise that every candidate fits the deployment's physical budgets or disk
quota. Store staging remains bounded independently of graph payload limits.
The record encoder measures before allocating, and Store admits the actual
changed rows and remaining staging bytes. Profile sizing can use conservative
owner contributions. A second exact preflight would repeat this work without
strengthening atomic refusal.

C projects page descriptors and copies foreign candidates into the retained
call. Rust owns temporary ABI spines through that setter. The session codec
owns fragment ordering and data coordinates, while hosting supplies exact
held fields for its resolver. Neither adapter owns another journal, authority
ledger or transaction engine.

## Memory accounting

The per-ingress retained-call allowance is separate from the Vat message queue
because those allocations have different lifetimes. Admission reserves the
complete call allowance to keep ingress fairness independent of preparation
progress. Actual backing grows incrementally in two stable block chains:
immutable inputs and restartable working storage. Standard fixed-buffer
allocators own placement within each block. The call owner clamps growth to its
remaining physical budget, including headers and unused space. URI parse state
uses short-lived chains charged to that same owner. Synchronous Host admission
consumes these borrows or copies its parked locator and Swiss bytes before
scratch retires. Pending results retain only their working state. Retiring
scratch therefore releases its blocks even when persistent working allocations
followed it. Canonical save URIs have one measured allocation. Unconstrained
arena growth can refuse a bounded working set because its next spare-capacity
request exceeds the remainder. Revision restart releases the working chain after
preparation and reads retire. Unknown outcomes retain it. Reply spines and bytes
remain valid and unchanged through settlement under the same retained owner. C
and local forwarding copy at their callback boundaries. Settlement therefore
retains authority without a second copy of the reply. Synchronous near calls use
the same input and working allowance. Their backing belongs to the turn arena,
and composite results copy into that outer lifetime before call storage retires.

Pure allocation queries compose private reference preparation, save and URI
parser costs. They account for canonical percent expansion and one shared
scratch window, then derive physical backing including placement padding, block
headers and growth slack. C/Rust reference sizing additionally includes the C
declaration spine and supplied URI copies. The complete call adds the graph
contribution, derived at the snapshot, candidate and staging owners and
projected through C/Rust. Aggregate payloads charge their sum and per-page
overhead. The managed-content invocation contribution derives retained input,
private state, occurrence-based held custody, receipt encoding/replay, C
argument projections and reply conversion at their owners. Complete incoming
argument topology includes mutation wrappers. Reply topology covers persisted
receipts as well as new results. Shared writer fragments bound receipt bytes
without a second encoding pass or a fixed maximum allowance for every tiny call.
Application allocations remain explicit. Single-record content/reference edits,
other management and forwarding paths, Store staging, Capabilities operations,
registration, settlement arenas, Rust buffers and Host network state have
separate owners. These queries do not admit work. The Store and attachment
retain admission authority.

Managed content staging projects a separate row-family contribution: one row for
the target and each ancestor, plus owner, change batch and history, with
optional mutation receipt and endpoint. Canonical recipe sizing is a separate
hosting contribution. Application root and pages use their registered schema
bounds. Sum retained encoded proposals and choose the largest record bound.
Temporary encoding and backend metadata remain separate. Re-proposals replace
one row's staged bytes, and obsolete pages remain collection debt. Creation and
other management effects have different participants. C/Rust project these facts
without adding a storage read or admission pass.

## Receipt replay

A committed mutation receipt replays after current admission and exact result
custody pass. It does not prepare unrelated content graph fields or new saves.
The receipt owns its result. Replacement preparation cannot become a dependency
of recovering an already-applied operation.

## Alternatives considered

Pinning every page would couple durable graph size to cache capacity. Following
every strong edge would mix page ownership with capability custody. A Rust
transaction adapter would duplicate commit and recovery ownership. The retained
snapshot instead pays an explicit bounded payload and edge copy.

## Evidence

[Graph proofs](../../../test/loam/access/content_graph_test.zig) cover cold
preparation, page roles, canonical bindings and revision fences. [Hosted
proofs](../../../test/loam/access/content_graph_hosted_test.zig) cover atomic
receipts, replay, one content event and partial staging refusal. The [session
codec trace](../../../apps/rooms/rust/proofs/src/session_storage/mod.rs) uses
the shared C/Rust boundary. The [session guide](../../rooms/session.md)
describes production capacity, exact effect admission, management and consumers.
