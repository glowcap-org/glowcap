---
id: ADR-0146
status: accepted
date: 2026-09-06
tags: [session, gc, wire-delta, listeners, resolvers, shortening]
decision: "An import row records how many of its wire retains the session itself will release (a linked V1.0 resolver's, a pending listener's, a stable shortening edge's) and a caller's `op:gc-exports` is validated against the remainder, so the session's own later release always finds its row."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0255]
---

# ADR-0146 Session-held import retains

## Context

Every retain on an import is one the partner's wire mention granted, and
ADR-0008's wire-delta accounting releases each with exactly one outbound
`op:gc-exports`. The session consumes some of those mentions itself: the
resolver a V1.0 deliver advertises, the listener an `op:listen` nominates, the
promise a shortening callback advances to. Each is released by a message the
session builds later, beside the callback, fire, or closure that spends it,
and each of those paths asserts the import row is still there.

Nothing distinguished those retains from an application's. The import table
kept one count per row, `checkGcExportDecrement` validated a caller's release
against that count, and `recordPreparedSend` applied the session's own release
through the same decrement. The fuzzer found the consequence: an application
release for a position a pending V1.0 answer's resolver was holding was
accepted, and the settlement then asserted the missing row into `unreachable`.
The listener's retain and the shortening edge have the same shape. Three
special cases beside one validator is the wrong owner for the fact.

## Decision

The import row carries the fact. `ImportRow` in
`src/ocapn/session/import_table.zig` is `{ count, session_held }`: every wire
retain, and how many of them the session keeps for a release of its own. The row
stores no `Slot` cell, because a far import is always the `remote_value` of its
own position. The row is 16 bytes, down from 24, and still carries the count.

Three verbs on the table own the split. `adoptForSession` takes one already
counted retain as the session's, at the seam that consumed the mention:
`PreparedInboundResolver.commit` for a V1.0 resolver, the engine's
`listenerEntryFromListen` for a listener (through `retainImportForSession`),
and `completeShortening` for a stable edge. `decrement` is a caller's release
and refuses `GcUnderflow` past `releasable`, the count less `session_held`.
`checkGcExportDecrement` reads the same `releasable` for whole-message
validation, on both tables under one name. `releaseSessionHeld` is the
session's release and cannot fail, because the session adopted what it
spends.

The session's own wire releases record through `recordSessionImportRelease`,
distinct from `recordPreparedSend`: the release paired with a listener fire or
resolver callback (`session_release_at_commit` in `pushEncodedPairFromPending`),
and the shortening closure a caller's release carries. That closure stays one
wire message: `expandGcExportReleases` appends the edge-owned entries behind
the caller's and returns their count, and `Peer.send` records the prefix
through `recordSend` and the suffix as the session's own. Which edges own a
retain is a fact on the edge row (`ImportedPromise.shortening_target_retained`),
set where the retain is adopted, so the planner reads it rather than inferring
it from a count a partner can move by re-introducing the source. The Host lifts an
application handle only from `releasable` retains, so a listener's or
resolver's mention can never be surfaced as a handle and released through it.

A listener entry owns one session-held retain on its listener import. The two
install verbs assert `listenerRetainHeld`, so a fixture built without the
retain fails where it is installed rather than where it fires.

## Scope (what this does not decide)

Export rows are unchanged: their local baseline is outside wire accounting and
`wireHeld` already names what a partner may release. The introduced-import
retains a shortening callback's deliver brings in and the engine releases in
the same transaction stay caller-kind. Nothing outside that transaction can
address them. A projected promise is a promise export of the recipient
session (ADR-0255), rooted by the partner's hold and collected on its release.

## Alternatives Considered

- **A reserved-hold floor per special case beside the validator**: the first
  fix. Rejected because the listener and shortening cases needed their own,
  and one of them has no reverse index from import to listener to consult.
- **A side map of session-held counts**: keeps the row at its old width.
  Rejected because a session retain's commit is infallible by contract and a
  map insert is not, and because the row was carrying a constant cell whose
  bytes the count replaces.
- **Two wire messages for the shortening closure**: a caller's release then a
  prepared session release. Rejected because the closure already had one wire
  form the tests pin, and recording two owners against one message costs
  nothing on the wire.

## Consequences

`ImportView` projects the constant cell for the REPL panes and carries
`session_held`. `Session.importSlot` does not exist. `Session.importReleasable`
is the bound the Host's lift reads. `recordPreparedSend` records no session
release. The fire's moot release and the resolver callback's paired release name
themselves. Test fixtures that install listeners by hand take the retain with
`retainImportForSession`.

## Evidence and gate

`test/engine/listener_fire_budget_test.zig` pins the listener case at the peer:
the release is refused, a caller's own retain on the same import is still
releasable, and the fire retires the row. `test/session/resolver_test.zig` pins
the resolver case and the shortening chain with its split record.
`test/engine/fuzz_test.zig` replays the program that reaches the resolver crash,
written draw by draw and validated by defeating both floors, and its listen
operation nominates real listener objects so fuzzed sessions hold session-owned
rows. `zig build check` carries the footprint and allocation budgets the
narrower row moves.

## Notes

ADR-0008 owns wire-delta accounting. ADR-0010 the V1.0 resolver link.
ADR-0255 the projected promise this leaves to its own release.
