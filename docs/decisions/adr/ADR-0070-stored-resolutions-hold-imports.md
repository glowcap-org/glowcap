---
id: ADR-0070
status: accepted
date: 2026-10-27
tags: ["gc", "promise", "session", "import-table", "pipelining"]
decision: "A resolution this side sends holds every import it names until the partner releases the answer, and the import table withholds any release of a held row from the wire."
supersedes: []
superseded_by: []
amends: [ADR-0068]
amended_by: []
---

# ADR-0070 Stored resolutions hold imports

## Context

A resolution this side sends stays stored for the answer's lifetime, and a
late call, listen, or projection the partner pipelines onto the answer
forwards to the partner objects the resolution names
(`engine/pipeline.zig`, `engine/pipeline_listeners.zig`). The application
may release such an object after the resolution is sent. The partner then
retires the import's position and may mint it again for another object, and
a forward keyed on the position alone would reach the wrong one. A check at
each consumer that this side still holds the import caught the released case
and not the reused one, and lived at five sites that each had to remember it.

The session already keeps imports alive for one kind of stored value: a
forwarded reply's result adopts the imports the reply introduced and
releases them through a preallocated batch when the answer payload dies
(`session/import_release_outbox.zig`).

## Decision

Every resolution stored with a `fulfill` value holds each far import the
value names (`ImportTable.holdForResolution`). The hold is a count on the
import row beside its retain counts, and a held row never retires, because
no release of a held row reaches the wire. The retains the application or
the session release while the row is held stay with the table, a caller's as
the session's and the session's as held back, and leave as one
`op:gc-exports` when the last hold does (`ImportTable.releaseResolutionHold`).

One rule covers every producer of an outbound release. Before encoding, the
producer asks `Session.wireRelease` what the frame carries: the whole
release, nothing, or the entries naming no held row. After encoding it
records the whole release as before, and the table withholds the held
entries at record time (`ImportTable.decrement`,
`ImportTable.releaseSessionHeld`). A caller's `op:gc-exports`, a session's
prepared release, the shortening closure either carries, and the single
entry a listener fire or resolver release emits all share it. A Host handle
lifted from a stored value while every retain is held back takes one retain
back, so its release is a caller's release again (`ImportTable.noteHostRef`).

The hold rides the forwarded-reply batch. A batch has two kinds: the stored
value's hold on the rows it names, and the retains a forwarded reply
introduced, which chain onto the hold. The answer payload owns the batch,
final release readies it, and the drain settles the hold before it encodes
what is owed. A stored resolution that names no far import allocates
nothing. The batch charges the retained-answer byte cap and counts against
the inbound-answer bound, so a partner that keeps answers open holds imports
only within limits this side set.

## Alternatives and consequences

Checking at each consumer whether this side holds the import keys on the
position, which the partner may reuse, and spreads one rule across every
reader of a stored resolution. Stamping imports with an incarnation would
need the partner to tell this side when a position changes meaning, which
CapTP does not carry. Refusing to send a resolution naming an object the
application might release has no moment to decide at, because the release
comes later.

An import a stored resolution names lives as long as the partner keeps the
answer. The application's release of it is deferred, not lost, and the
existing retained-answer caps bound what a partner can pin. Every import row
carries two more words. Revisit the hold if OCapN gives an answer position a
form for naming a released object, or if the hold's byte cost at scale calls
for a sparser side table.

## Evidence

`test/session/held_import_test.zig` holds the table rule: a caller's and the
session's release of a held row stay with the table, a second hold keeps
them, a lifted handle takes one back, and `wireRelease` drops held entries.
`test/engine/peer/pipeline_remote_forward_test.zig` holds the engine
behavior: a late call, listen, and projection reach the released object, a
mixed release sends only its unheld entries, and the retains leave when the
answer is released. `test/driver/promise_argument_test.zig` lifts a settled
answer naming a released partner object, and `test/c_abi/host/turn_test.zig`
releases the promise handles before the pump with the partner's early poke
still landing.
