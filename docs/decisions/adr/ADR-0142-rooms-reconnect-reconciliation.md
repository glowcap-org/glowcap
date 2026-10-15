---
id: ADR-0142
status: accepted
date: 2026-09-03
tags: [rooms, identity, reconnect, history]
decision: "Rooms replaces stale live nickname claims only when authenticated peer identity or the old registration's one-use proof establishes continuity, and merges recovered session-archive rows into the live timeline instead of assuming every recovery is a prefix."
supersedes: []
superseded_by: []
amends: [ADR-0135, ADR-0138, ADR-0139]
amended_by: []
---

# ADR-0142 Rooms reconnect reconciliation

## Context

A browser may resume and establish a new directory connection before the server observes the suspended transport's
terminal edge. Treating the still-live nickname row as a stranger's claim refused the reconnect. Retrying for a fixed
number of seconds only made correctness depend on teardown timing. An attached shared-session view has the symmetric
ordering problem: after suspension, its archive read can contain messages newer than the live rows already projected.
Prepending every archive answer put those missed messages at the top until reload started from an empty timeline.
The archive and attached delivery queue also stamped the same event separately. Queue delay therefore changed its time,
and replacing an archived row during an edit could move the original message to the edit time.

Both failures treat reconstruction as replay from an empty state instead of reconciliation with a live, partially
stale owner.

## Decision

The Rooms server's live index derives one connection-claim comparison from the session identity already authenticated by
the realized channel. A same-peer connection can replace the old room seat and directory registration directly. When
the directory channel cannot prove the browser's identity, the old registration's name capability mints a one-use
voucher. The browser or durable session keeps that voucher in runtime memory and presents it to replace the registration
before room reconstruction fans out. Each replacement mints a fresh proof. Connection-bound capabilities are released
rather than transferred, and no proof enters a workspace or checkpoint.

The attached browser projection reconciles archive rows by their opaque archive coordinates. A matching row receives
the archive's current edit, withdrawal, and file shape without replacing unchanged file custody. Missing rows enter the
observed log through a stable chronological merge. The conversation event owner stamps an occurrence once before archive
and live fan-out. Archive replacement keeps a line's first time, and the live conversation's monotone order resolves
ties that millisecond time cannot distinguish. Archive coordinates remain identity-only. Ordinary room-retained history
and separately shared archives remain explicit prefix operations because those sources do not claim to fill a gap in the
attached session's own event stream.
Attached topology snapshots and line events share one delivery order. Snapshots may coalesce but cannot overtake an
older line. Any bounded history operation that trims the unread anchor moves it to the oldest retained row, or clears it
with an emptied log.

## Scope

An unauthenticated connection without the live registration's voucher retains the collision rule until the old
connection closes. A new browser Host, another tab, and a later holder of the same nickname do not inherit the claim or
direct-message history. This decision does not make timestamps global ordering authority across peers. It orders one
session archive against that session's own projected event times.

## Alternatives Considered

- **Longer or unbounded nickname retry**: rejected because teardown duration is not identity proof, and a real collision
  would become an indefinite reconnect.
- **Always prepend or append recovered archive rows**: rejected because either choice fails when recovery spans the live
  timeline's boundary.

## Consequences

`RoomLiveIndex` owns authenticated claim comparison for room membership, directory registration, and WebRTC designator
collision checks. The directory's name capability owns one-use continuity for relayed browser sessions. The browser
store owns history reconciliation as an operation distinct from prefix hydration. The presentation layer carries no
timed room reconnect-claim state machine.

## Evidence and gate

`apps/rooms/rust/application/src/server/directory/tests.rs` distinguishes a
reconnecting authenticated peer from a different peer. The server name-voucher
scenario moves a live registration before its old connection closes.
`apps/rooms/test/session/archive_reconciliation_test.ts` resumes an attached projection with missing archive rows on both
sides of an existing live line, including an edit and withdrawal missed during suspension. The archive backend scenarios
hold creation time across replacement and restart. The attached-delivery scenario holds the pre-queue event time, and
orders snapshots behind earlier line events. Store scenarios give equal timestamps their conversation order without
interpreting opaque archive identity and keep unread rules anchored after reconciliation trims. The repository gate
remains `zig build check`.
