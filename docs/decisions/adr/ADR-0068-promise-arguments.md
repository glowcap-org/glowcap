---
id: ADR-0068
status: accepted
date: 2026-10-26
tags: ["pipelining", "desc-answer", "promise", "driver", "host", "c-abi"]
decision: "A received answer reference lifts to a Host capability promise that settles with the answer."
supersedes: []
superseded_by: []
amends: [ADR-0003]
amended_by: []
---

# ADR-0068 Promise arguments

## Context

CapTP lets a caller pass a promise as an argument. On the wire that is a
`desc:answer` reference naming one of the caller's pending questions, which
the receiver holds as an inbound answer. The session layer already admits
such a reference (`session/validate/passable.zig`) and the engine already
settles every inbound answer through one funnel
(`engine/outbound/drain.zig`), whether the application, a forwarder, a
projection, or a resolution chain settled it. The Host refused the reference
when lifting arguments into application values, so a hosted object could not
receive a promise the caller had not yet resolved, while Goblins peers send
them freely. ADR-0003 made a pending answer a send target for the sender. This
record makes a received pending answer a capability for the receiver.

## Decision

A received `desc:answer` reference lifts to a Host capability promise, the
same kind of row an inline give already creates
(`driver/core/capability_promise.zig`). The row's identity dimension is the
answer's exact incarnation, `AnswerTarget` (name plus row id), so two
occurrences of one answer lift to one capability and a reused wire position
never aliases an older question. The answer payload records which Host promise
watches it, and the Host retains the payload so the stored resolution survives
`op:gc-answer`.

The Host learns of settlement through the Node action queue it already drains
for inline-give settlement. When the engine drains a settled answer whose
payload names a Host promise, it publishes one action on a seat the Host
reserved at lift. The Host pump follows the engine's resolution chain walker
to a terminal outcome: a reference lifts through the ordinary capability lift
and fulfills the row, data fulfills the row with an owned value whose nested
capabilities are retained, a break breaks the row, and a chain that lands on
another pending answer moves the subscription there. An answer already
settled at lift time takes the same path at once, and a settled reference
shortens to that capability with no promise row.

A capability promise therefore has a data settlement. A send or tell to a
promise that settled to data breaks with the uncallable-target reason, and a
listen fulfills with the data. Settlement, backpressure parking, and queued
operation dispatch stay in the one row state machine.

Each session is held to a bound on lifted answer promises, a `SessionLimits`
field beside `max_pending_withdraws`, with a typed refusal before any retain
or row exists. Closing the session that owns the answer breaks every promise
lifted from it through the same path that breaks its inline gives. Each row
is a named cost in the memory ledger.

Outbound, a public Host vow is passable as a capability argument. Within the
vow's own session it lowers to `desc:answer`. Across sessions it lowers
through the local promise projection ADR-0003 already names. One Host verb
and one C verb perform that projection, and each binding's send accepts its
promise type where it accepts a capability. A vow passes in any state until
its handle is released. The vow row keeps the completion the embedder drained,
so a vow asked for after it settled projects as a promise settled to that
completion: its data, the capability it named, or its break. The row names a
capability without retaining it, so the application's own release still
reaches the wire at once, and a promise asked for after that release breaks.
A promise asked for between the fire and the drain is staged by the drain. A
broken promise has no value to pass, so a send that names one is refused.

## Alternatives and consequences

Settling the row from the Vat's reply alone would miss forwarded, projected,
and chained settlements, which only the engine funnel sees. A new engine
event kind cannot carry the notification, because event kinds mirror wire
message kinds exactly. A Host-side map from answer identity to promise would
duplicate a fact the payload can own. Cloning the resolution at lift would
copy what the retained payload already holds.

The row grows one origin arm and one settled-data arm. A listener that
awaits data receives a value rather than a capability, which the Host vow
surface already delivers. Revisit the bound if a workload needs more lifted
promises per session than the withdraw bound allows, and revisit the chain
handling if OCapN adds a wire form for third-party promise shortening.

## Evidence

`test/driver/promise_argument_test.zig` is the acceptance test: a promise
argument reaches the hosted object as a capability that settles with the
answer. Driver tests on `capability_promise` cover data settlement and the
bound. The Goblins interop scenarios and the OCapN conformance manifest hold
the wire evidence, and `docs/boundaries.md` no longer lists the refusal once
every step of [the plan](../../planning/promise-arguments.md) lands.
