---
id: ADR-0131
status: accepted
date: 2026-08-25
tags: [rooms, capabilities, persistence, browser, security]
decision: "A Rooms reader explicitly selects one whole-archive sturdyref in the archive-peer form Settings opens. The browser validates it with a bounded read before an ordered recorder swap, keeps the bearer below presentation state, and stores it in browser local storage only when the reader opts in. An unreachable selected peer becomes visibly unavailable and receives no device-store fallback; retry preserves the original remember choice, while returning to device history is a separate action."
supersedes: []
superseded_by: []
amends: [ADR-0130]
amended_by: [ADR-0132, ADR-0133, ADR-0136]
---

# ADR-0131 Browser archive peer selection

## Context

ADR-0130 gives the member archive a durable peer and whole-archive sturdyref.
Without a browser selection boundary, that peer is callable infrastructure but
not a Rooms feature. Selecting it also decides where new plaintext goes, how
an existing recorder stops, what happens while the peer is unreachable, and
whether the browser retains the bearer after the page closes.

A silent fallback would create two histories under one visible selection. An
automatic remembered bearer would keep read-and-write authority on a device
without the reader choosing that custody.

## Decision

The archive-peer form Settings opens accepts an archive sturdyref in a secret input. The page
parses it, connects, enlivens the object, and makes one bounded `read` before
changing the recorder. One page-owned selection controller serializes candidate
validation, target activation, selection metadata, and retirement, so concurrent
submissions cannot leave those facts naming different peers. A failed candidate
leaves the current recorder untouched. The presentation store receives only a
label and connection state; the sturdyref, session, and archive reference remain
with that controller.

Changing targets first drains writes assigned to the old target. Reads already
using it finish before its session closes. Later direct-message writes and
history reads use the new target. Recovered groups name the archive peer, recorder source, and conversation
generation that supplied them. No records migrate during a target change.
Once the new target is active, refusal while retiring the old one is a cleanup
diagnostic rather than grounds to roll back the committed selection.

The reader may explicitly remember the sturdyref in browser local storage. A
page-lifetime selection removes any earlier remembered value. Retry preserves
that choice rather than turning an ephemeral bearer into retained authority.
Returning to this browser's archive is a separate action that removes the
remembered peer.

When a remembered peer cannot be reached at startup, the page selects an
unavailable target and says so. It does not write those lines to IndexedDB.
The same state change follows an operation that fails after the peer's session
has ended; later operations refuse quickly until retry or an explicit return to
the device recorder. A record refusal or unavailable blob remains local to that
operation and does not falsely mark a live peer unavailable. Turning history off
stops future peer writes, but cannot claim to erase a remote archive whose
contract has no erase verb.

## Scope

The selected sturdyref grants read and write access to the whole archive.
Settings does not mint scoped, read-only, or revocable facets. ADR-0132 adds a
separate direct-conversation surface that mints and hands over a narrowed
read-only facet from the selected recorder. Target changes do not copy existing
records. Attachment metadata follows its line record, while bytes stay behind
the selected archive's scoped blob capabilities.

## Alternatives considered

- Falling back to IndexedDB while offline was rejected because it makes one
  visible recorder conceal two authorities and requires a later merge policy.
- Remembering every pasted sturdyref was rejected because browser persistence
  of a bearer is a separate custody choice.
- Putting the sturdyref in the application store was rejected because ordinary
  rendering and diagnostics do not need archive authority.
- Migrating device history during selection was rejected because selection and
  transfer have different failure, duplication, and provenance semantics.

## Consequences

A selected peer is one explicit recording destination. Offline sends still
travel to their recipient, but their archive write is declined and Settings
shows the unavailable recorder. The reader chooses whether to retry it or use
this browser instead.

The whole-archive sturdyref remains sensitive even when stored only by opt-in.
ADR-0132 keeps that bearer out of handover by narrowing from the active recorder
only when the reader shares one direct conversation.

## Evidence

`apps/rooms/test/archive/target_test.ts` proves serialized concurrent selection,
ordered target retirement, post-commit cleanup refusal, operation-local failure,
keeper attribution, and refusal without device fallback.
`zig build rooms-web-archive` drives Chromium against a live iroh archive peer,
writes direct-message history, closes the browser profile, and recovers the
attributed line from the same sturdyref in a fresh profile.
