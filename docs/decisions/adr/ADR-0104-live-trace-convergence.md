---
id: ADR-0104
status: accepted
date: 2026-08-03
tags: [driver, c-abi, bindings, observability, rooms]
decision: "Traces from several peers converge on one endpoint without their traffic converging. The core reports each session's OCapN session identifier — the one name both of its peers derive — and tags each message with a hash of its own wire bytes, so a consumer can tell one wire watched twice from two unrelated wires and fold two sightings of one message together; the endpoint, never the producer, assigns the namespace every session id is scoped by and restamps time, and it forwards both ends of a wire because what to draw is the viewer's decision; the consumer builds its graph edge-first, so a peer's identity falls out of what the two ends of an edge say about each other; and an embedder that cannot take a C function pointer drains the same facts from a fixed ring instead."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0106, ADR-0120]
---

# ADR-0104 Live trace convergence

## Status

Accepted and implemented. The wire name is `driver_core.trace.wireName`, the
drained seam is `pancake_host_set_trace_queue` plus `pancake_host_next_trace`,
and the endpoint is `apps/rooms/server/viz.ts` with its producer half in
`apps/rooms/lib/viz_publish.ts`.

## Context

The rooms server enables the trace veneer and serves the records over a
WebSocket, so a viewer watching that feed sees the room's sessions as they
happen. It sees nothing else, and the thing it is missing is the interesting
one: a direct message.

A rooms DM is a session between two members. The room introduces them
(three-party handoff), the recipient redeems the give by dialing the exporter,
and from then on the two members talk directly. The session lives on the
members' own hosts, in their own processes — two browser tabs, or a tab and a
native client — and the room is not on its path. A room server can no more
report that session than it can read it.

The obvious repair is the one that must not be made. Routing DM traffic through
the room so the room can report it would trade away the property the whole
three-party handoff exists to buy. What may converge is telemetry. What may not
is the conversation.

Letting each peer report its own trace to a shared endpoint runs straight into
three problems, and the first is the one that would have made a merged feed
silently wrong.

**Every producer numbers its own sessions from one.** A veneer mints
`live-h{cookie}-s{id}`, where the cookie counts hosts within one process. Two
producers therefore both call their first session `live-h1-s1`. A consumer keys
peers and sessions on that string, so merging two producers' feeds as they
stand would braid unrelated sessions into one row and draw a picture of
something that never happened. This is exactly what the architecture rule's
Names section is about: a bare id carries its namespace only in the author's
head.

**Both peers of a DM trace it.** Neither is more entitled to report it than the
other, and the tap reports both directions of traffic, so each peer's view of
the session is complete on its own. Forwarding both would draw one conversation
twice, with every message doubled.

**A browser cannot take a trace callback.** The wasm module declares exactly
the behavior-dispatch and hosted-retirement imports, and `zig build
wasm-import-check` holds that fixed set. `pancake_host_set_trace` wants a third,
arbitrary C function pointer, which has no wasm form. The browser peers are the
very peers whose DMs are invisible.

## Decision

### The core reports the one name both peers agree on

`driver_core.trace.Event.session_open` carries a `wire`: the OCapN session
identifier, written as 64 lowercase hex digits.
`foundation.crypto.sessionIdFromPeerIds` already derives it from the two
sides' public identifiers with the pair sorted, so the dialer and the accepter
compute the same value. It is protocol identity, not a producer's claim, and
it is the only name two processes tracing one conversation can agree on
without being told anything.

The core computes it where it already holds both keys, at the open fact, and a
partner that sent no session key leaves it empty rather than guessed.

### A session's identity is separate from what a human reads

An open's `a` endpoint is the reporting host's own key designator, which is
what a partner names that host by, so a peer stays one node however many
producers report it. What an application would like its own endpoint *called*
travels beside it as `a_label`, display only. The two are different facts and
collapsing them costs one of them: a designator is a correct identity and a
poor label, a nickname is a good label and cannot be an identity, because it is
text a producer chose. The consumer's ledger holds the same line for the
partner endpoint already — an annotation renames, and never merges or splits.

A third self-statement rides beside those two: `a_profile`, the implementation
the producer says it runs. It is stated rather than deduced because these
records are a schema and not one implementation's mark, and the conformance
Goblins peer publishes them too. A consumer that read an implementation off the
fact that a record arrived would draw every producer as whatever it expected;
a producer that says nothing is honestly unknown instead, including a pancake
one. It is the same class of thing as the `provenance` verdict beside it, a
conclusion the producer states rather than a raw wire fact.

### The endpoint owns every name a viewer keys on

A producer connects to `/publish` and sends; a viewer connects to `/` and
receives. A producer's socket carries nothing back, so it is telemetry and can
never become a channel between peers.

The endpoint assigns each producer a scope at connect and prefixes every
session id with it. Assigned rather than claimed: a producer-chosen namespace
can collide with another producer's and can be forged to name one. It also
restamps `sim_t_ns` on arrival, because two producers share no time origin and
arrival is the only clock a merged stream has in common, and it owns `seq`,
`epoch`, and the replay mark, which a producer is not allowed to state.

Because the scope belongs to the connection, a reconnecting producer gets a new
one, and the sessions it still holds have to be announced again under it. The
producer half keeps exactly what the endpoint keeps for a reconnecting viewer —
the live opens and their latest annotations — and sends that first on every
connection. History is not resent, at either hop.

### Both ends reach the viewer, and one message has one tag

When two producers report the same wire, both views are forwarded. Choosing one
and dropping the other is a decision about what to DRAW, and the endpoint is
the transport: the dropped view carries its end's annotations, its end's
closes, and the half of a conversation only that end can see, and none of it
comes back. A member closing a direct message from the end that happened to
lose the election is exactly that, and the feed stayed silent.

What lets the viewer draw one conversation from two views is a tag on each
message: `driver_core.trace.Event.message.digest`, a 128-bit BLAKE3 over the
frame's own wire bytes. One frame crosses one wire, so both ends hold the same
bytes and derive the same tag with nothing to coordinate and nothing retained
per session, and it is derived rather than claimed — a producer cannot assert
that some other message is this one without holding its bytes. The consumer
enters a tag on the first sighting and CONSUMES it on the second, so a peer
that genuinely sends identical bytes twice still draws twice.

A producer that disconnects takes its own view with it, closing those sessions
on the live feed, so a viewer that reloads does not meet the ghosts of a peer
that left. A session whose other end is still watching stays: the consumer
closes an edge when the last end reporting it says so, because a telemetry
socket dropping is not a conversation ending.

### An embedder that cannot take a callback drains a ring

`pancake_host_set_trace_queue(host, capacity, payload_cap)` captures each fact
into a fixed ring the embedder pops with `pancake_host_next_trace`, borrowed
until the next pop — the lifetime `pancake_host_next_action` already carries.
It is a separate queue from the action queue on purpose. An action is a promise
the host must keep, so the action FIFO reserves capacity ahead of every push and
can never refuse one. A trace record is an observation, and must never make the
protocol wait: this ring is fixed at install, refuses nothing, and drops
instead, counting what it dropped so a consumer reads a gap rather than
inventing continuity. It drops the *newest* record, because the oldest is the
causal prefix a consumer keys everything else by.

The TypeScript veneer uses that seam everywhere, native and browser alike, and
drains it on the same unwind that drains the action queue. One mechanism means
a browser peer and a native one produce the same stream through the same code.

### The consumer builds its graph edge-first

A session is the strongly identified thing: both of its ends derive the wire
name, and neither had to be told it. A peer is not — the room cannot verify
who a member is, because a browser tab dials as an ephemeral client and signs
the unreachable-client placeholder. So `apps/ocapnviz`'s `StageLedger` keys
edges by wire and lets node identity fall out of what the two ends of an edge
say about each other: the side one end could not name is whichever producer
says it is on that wire. Two members in a room draw as three peers rather than
five, and a member's direct message hangs off the same node its room session
does.

That inference is a claim and is written as one. The producer is trusted about
itself and about nothing else, which is the same footing the rest of a
development-time loopback endpoint stands on. It never overrides a name a
durable identity proved.

One consequence has no order-free alternative and is taken deliberately. From a
single observation of a wire whose partner is unverified, the other side's name
is not derivable — so a picture that draws immediately must be able to learn.
When the far end later speaks for a side already drawn as a placeholder, that
edge is redrawn between the two real peers and the placeholder leaves. The
timeline gives an id one lifetime, so the redrawn edge is a new incarnation.
Deferring the first draw instead would mean waiting on a producer that may
never connect.

## Scope (what this does not decide)

- **The merge is a claim, not proof.** Joining the room's view of a member to
  that member's own view rests on a producer asserting which wire it is an end
  of. Proving it would need the tab to advertise and prove its own durable
  identity to the room — a handshake posture change (ADR-0097's territory), not
  a telemetry one, and making it to improve a picture would be the wrong
  reason. The endpoint binds loopback; nothing here makes it safe to expose.
- **The endpoint is not an authentication boundary.** A producer's records are
  bounded and schema-checked, and its scope is assigned rather than claimed, so
  one producer cannot name another's sessions. It can still describe sessions it
  invented, and it can label its own node anything. The endpoint binds loopback
  and is a development surface; nothing here makes it safe to expose.
- **Rust, Python, and Racket keep the callback seam.** They can take a function
  pointer, which is lossless and allocates nothing, so the ring's omission from
  those bindings is recorded on the symbol rows rather than being a second way
  to say the same thing.
- **What a peer is CALLED when no application claims a name.** A merged node
  shows the name it joined under, which for a side first seen as an unverified
  claim is that claim's disambiguated representation. A designator would be sixty-four
  hex digits and no better. Nothing here decides what a viewer ought to render
  for an unnamed peer.

## Alternatives Considered

- **Route DM traffic through the room so the room can report it.** Rejected
  outright: it trades away the property three-party handoff exists to buy, and
  the request that prompted this work named it as the failure condition.
- **Elect one observer per wire at the endpoint.** This is what shipped first
  and it is what this ADR now supersedes in its own text. It draws a direct
  message once, which was the goal, at the cost of everything the suppressed
  end knows — including its closes, so closing a direct message from the wrong
  end did nothing at all. It also put a drawing decision in the transport.
- **Let each producer choose its own namespace (a label, a UUID).** Rejected.
  A client-chosen name can collide with another client's, and can be chosen to
  collide. The endpoint owns the table, so the endpoint assigns the key.
- **Key sessions by the wire name alone and drop the producer scope.** Rejected
  because a session has a wire name only once its handshake proved both keys,
  and every message record names the session id, including on a session whose
  partner sent no key. The scope is what makes an id a name at all; the wire is
  what tells two names apart from two views of one.
- **Add the trace callback as a second wasm import.** Rejected. The single
  import is a load-bearing property of the browser binding, and a synchronous
  JavaScript callback running inside the pump is the backpressure hazard a
  drained queue does not have.
- **Put trace records on the existing action queue.** Rejected. Actions are
  reserved ahead so their pushes cannot fail; telemetry either breaks that
  guarantee or lets an observation exhaust the host. They are different
  contracts and belong in different queues.
- **Have each peer publish to the room server over CapTP.** Rejected: it makes
  a DM peer know about rooms, and it puts telemetry on the capability graph the
  visualizer is drawing.

## Consequences

A direct message between two browser tabs appears on the same timeline as the
room's own sessions, with the room off its path;
`apps/rooms/test/web_dm_viz_test.ts` drives that end to end and reads the
endpoint as a viewer would. `apps/rooms/test/web_viz_lifecycle_test.ts` drives
a member's whole life in a room — join, direct message, leave, close, reopen,
go away — and after every step counts the peers and sessions through ocapnviz's
own converter, so the picture rather than the feed is what is held.

`PancakeTraceEvent` grows five fields — `wire`, `wire_len`, `frame_total_len`,
`dropped`, and the fixed-width `digest` — so the generated header, the
TypeScript ABI mirror, and the three bindings' struct mirrors move with it.
pancake ships under no compatibility promise, so this is a regeneration, not a
migration. The header generator learned to emit a fixed array field, which C
splits across the type and the declarator.

A host with a trace queue installed holds `capacity * payload_cap` bytes plus
the slot array, in two allocations made once at install. A host with none holds
one null pointer, and the per-session footprint budgets are untouched: the ring
is host-scope, and the core's own sink is the one null check it always was.
