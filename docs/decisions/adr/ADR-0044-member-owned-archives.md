---
id: ADR-0044
status: accepted
date: 2026-10-19
tags: ["rooms", "capabilities", "persistence", "browser", "identity", "storage", "iroh", "security"]
decision: "An archive is an ordinary capability with bounded put and revision-read operations."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0044 Member-owned archives

## Context

A person's retained account of a conversation is distinct from public-room scrollback and another person's archive. Names and fresh session keys cannot safely merge those accounts.

## Decision

An archive is an ordinary capability with bounded put and revision-read operations. Records carry opaque source and conversation-generation coordinates. Edits and withdrawals update their standing representation rather than preserving withdrawn plaintext as an immutable event history.

A reader explicitly selects its recorder and validates a remote archive before swapping. Offline failure remains visible instead of silently starting a second device recorder. Persisting a bearer in browser storage is an explicit choice.

Narrowed facets intersect scope and can only remove write authority. Live person-to-person handover is one-shot and tied to its session. Independently revocable durable shares have their own publications and tombstones. Attachment digests identify data but confer no authority beyond the archive facet that permits access.

Several held archives can contribute a combined read view. Recorder coordinates coalesce matching records, attribution retains their keeper, and writes still go only to the selected recorder. Reading another account does not silently copy it into local history.

A standalone archive peer uses one state directory, lifetime writer custody, a bounded synced log and atomic compaction. Startup refuses malformed history except the exact final append boundary it can prove torn.

## Alternatives and consequences

Nicknames are reusable, full-snapshot writes scale with retained history, and an implicit offline fallback creates two undisclosed authorities. Sharing an entire archive for one conversation overgrants. Blob lookup by digest alone would bypass scope.

Acknowledged immutable uploads can be reused within bounded retained custody. Neither the archive nor UI invents authoritative message ordering by matching text.

## Evidence

Archive, attachment, facet, recorder-swap and combined-view proofs exercise these contracts. [Rooms](../../../apps/rooms/README.md) and [stability](../../stability.md) describe the shipped operation and remaining limits.
