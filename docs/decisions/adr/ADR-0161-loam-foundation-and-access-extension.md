---
id: ADR-0161
status: accepted
date: 2026-09-14
tags: [loam, access, persistence, architecture]
decision: "Make Loam glowcap's optional persistence foundation with an included managed access extension. Keep graph persistence independent of resource policy and integrate execution through the existing Host and Vat."
supersedes: []
superseded_by: []
amends: [ADR-0153, ADR-0157, ADR-0159]
amended_by: [ADR-0162]
---

# ADR-0161 Loam foundation and managed access

## Context

Capability applications need durable objects and references even when they do
not use managed resources. Applications with editable sharing also need common
scope, grant, delegation, and lifecycle semantics. Providing both within glowcap
removes repeated application machinery and keeps the costs optional.

## Decision

Loam is glowcap's graph persistence and bounded-residency foundation. Resource
access lifecycle management is its included managed access extension at `src/loam/access/`,
exposed through `glowcap.loam.access`. Loam works without instantiated managed access state.
The planned C companion is libglowcap_loam. Managed access requires no separate archive.

Loam core owns typed records, edges, retention, bounded leases, and transaction
and recovery state. Managed access owns resource relationships, policies, current-authority
admission, grant lifecycle, and authorized observation. Managed access participates in
Loam transactions with ordinary application records. It owns no independent
database, pager, actor registry, or recovery executor.

Actor activation and durable execution use the existing Vat and Host. Adapter
I/O runs through the existing embedding executor. Neither layer adds an engine,
driver, Host, Vat, scheduler, or event loop. Core-only networking requires no
persistence, and local persistence requires no network session.

Application schemas, storage formats, and wire codecs remain separate
contracts. Reuse encoding primitives without coupling disk identity to CapTP
session tables or a connection codec. Host integration preserves exact stored
capability authority. A record codec never selects the authority to restore.

The [Loam architecture](../../loam/architecture.md) and
[API contract](../../loam/api.md) own implementation boundaries.
The [managed access architecture](../../loam/access-architecture.md) and
[API contract](../../loam/access-api.md) own resource-management semantics.
The research plan continues to require comparative physical-store evidence.

## Implementation and verification

The [shipped inventory](../../shipped.md#resource-models) owns current coverage.
[ADR-0162](ADR-0162-loam-record-transactions-and-lmdb.md) specifies the native
record/transaction implementation and immutable collections boundary. Sleepy
actors, hosted managed access, and the companion ABI remain planned.

Module imports and the public namespace inventory enforce the implemented
boundary. Resource tests run under `test/loam/access/`. Future modules must extend
those checks and prove independent plain-record and managed access consumers, matching
native/browser state transitions, and bounded memory under cold activation.
The 500,000-session target remains a measured networking goal, not a claim
that the persistence design has achieved that workload.
