---
id: ADR-0072
status: accepted
date: 2026-10-29
tags: ["rooms", "session", "loam", "concurrency"]
decision: "A managed Rooms gesture is stale only when the workspace intent changed after the revision it was prepared at, so receipt and custody commits never conflict it."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0072 Workspace intent fence

## Context

A managed Rooms session keeps its intent, custody, provenance and receipts in
one Loam resource, and every commit to it advances the resource's content
revision. Each gesture names the revision of the snapshot it was prepared at,
and the runtime answered `conflict` whenever that base differed from the
current revision (`runtime/src/session/managed/content/commands.rs` and the
acquisition, import, bridge and upload admissions).

Most commits leave the intent alone. Admitting any command installs its
receipt, settling one rewrites it, and imports add custody, so a person typing
in one conversation conflicted a gesture in another. The page re-prepares a
conflicted gesture a bounded number of times, checking each time that its
original selection is unchanged (`session/command/selection.rs`). Under load,
the runtime's own receipt and supervision commits used up that bound before
any person changed anything. The gesture then failed and stopped draft sync.

## Decision

The workspace pages store a fence beside the intent: the content revision
read by the write that last changed the intent (`records::Fence`). The one
intent writer, `records::replace`, re-encodes the intent and advances the
fence only when those bytes differ from the stored ones
(`records::encode_replacement`). Receipt-only writes keep the workspace pages
and never touch it.

Every admission compares a base with `Fence::admits`. A base is current when it
is no newer than the record and newer than the fence. Commands, bridge and
upload admissions resolve their targets from the current intent, and that
intent equals the one they were prepared against. Acquisitions that install a
complete candidate intent find the same base intent under the candidate, so
the candidate carries only the gesture's own delta. A stale acquisition still
recovers only as an exact replay. Ordinary result participation checks the
delta of every candidate the fence admits.

## Alternatives and consequences

A fence that ignores the live observations supervision writes (inbox, files,
seat, subject, lines, directory name and nickname) would admit more. But
posting gestures treat a changed seat, subject or files as different
authority, and `startDirect` depends on the directory's name and inbox. Only
the page's per-command selection check knows each footprint, so observation
churn still conflicts and re-prepares through it.

Raising the re-preparation bound would hide the cause and leave every receipt
commit conflicting every gesture prepared before it.

Comparing encoded bytes avoids decoding the stored intent. An equal intent
that encoded differently would advance the fence early and cause a needless
conflict. It could never admit a stale gesture.

## Evidence

The record codec proof (`proofs/src/content_session/records.rs`) re-encodes
an unchanged multi-page intent to its stored bytes with the fence kept, and
proves a changed intent advances it and that `admits` refuses earlier and
future bases. The Rooms page proof (`zig build rooms-web-page`) exercises the
page under concurrent supervision.
