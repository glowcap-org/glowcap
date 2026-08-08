---
id: ADR-0106
status: proposed
date: 2026-08-04
tags: [observability, ocapnviz, capability, rooms, authority]
decision: "A viewer drives only the endpoints it was handed a key to. An endpoint that has something to offer publishes one viz control object at an unguessable swissnum, reached by an ordinary sturdyref; the object answers one verb that returns a list of entries, each carrying a live capability and a display label, and the viewer renders exactly what came back. Watching stays the one-way trace stream ADR-0104 built and is not touched. Nothing here is implemented, and no endpoint in the tree yet has a control worth offering."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0106 The viz control capability

## Status

Proposed, and **not implemented**. Nothing in `src/` or `apps/` publishes a
control capability, dials one, or renders one. This record exists because the
machinery that pretended to do it has been deleted, and the reasoning that
replaced it needs somewhere honest to live. See Scope.

## Context

ocapnviz can connect to a live endpoint and draw what that endpoint reports.
Until now it also showed three buttons — Pause, Resume, Step — under a "Drive
sim" heading, compiled into the viewer and shown whenever it was connected to
anything.

They never worked, and the reason is the interesting part. They were not a
broken control. They were a control that assumed a capability the far end never
had. The viewer wrote `{"v":1,"cmd":"pause"}` onto its own websocket; the only
live endpoint in this repository gives producer sockets an `onmessage` and
viewer sockets `onopen`, `onclose` and `onerror` and nothing else
(`apps/rooms/server/viz.ts`), so the bytes were dropped on the floor. The
matching ack could only arrive as a `ControlAcked` record, which no producer
anywhere emits, so the panel's status pill was pinned forever on "no commands
sent yet". The panel's own comment explained that sends land only when a bridge
was launched with `--accept-stdin-commands`, a flag whose only occurrences in
the tree were that comment and its neighbours.

This is the defect [described-vs-built](../../../.agents/rules/described-vs-built.md)
names, in user-interface form, and the interface form is worse than the comment
form: a reader who opens a panel of buttons concludes the buttons do something.

The same assumption had a second home one layer down. `live-feed.ts` dispatched
on `HostJoined`, `MessageInFlight`, `LinkUp`, `LinkDown` and `SimStarted`, base
kinds from the retired pre-Zig render bridge. `pancake griddle` emits
snake_case (`host_joined`, `message_in_flight`) and the only reader of those is
the offline converter `apps/ocapnviz/scripts/griddle-import.ts`, which is a
shell pipe into Play mode and never touches the live path. So the live path
carried a whole ingestion vocabulary for a producer that does not exist, and its
tests passed because they manufactured the inputs themselves.

The question this record answers is what should stand where that stood.

## Decision

**A viewer watches everything it is fed, and drives only the endpoints it was
given a key to.** Watching and driving are two separate grants, acquired
separately, and the split is the design rather than a caution attached to it.

**Watching is untouched.** The convergence endpoint, the one-way websocket, the
producer scopes, [ADR-0104](ADR-0104-live-trace-convergence.md) entire. An
earlier form of this design had the capability carry the trace stream too, and
three facts killed it. ADR-0104's endpoint exists to assign the namespaces that
keep two producers' session numbering apart and to own `seq`, `epoch` and
arrival time, because two producers share no clock; a viewer talking to each
producer directly would have to reinvent all of it. ocapnviz has no pancake
dependency at all, so making the read path a CapTP peer would charge every
watch-only viewer a wasm Host, a relay URL and a locator. And observation is
many-to-one while control cannot be: the feed hands out a producer scope, not a
dialable locator, and it must not hand out one, or the telemetry endpoint
becomes the peer-to-peer broker ADR-0104 refused to be.

**Driving is a capability.** An endpoint with something to offer publishes one
**viz control object** at an ordinary swissnum, reached by a sturdyref of the
spec's own form, `ocapn://<designator>.<transport>/s/<swiss-num>`. An operator
hands that string to a viewer. The viewer dials the locator and enlivens the
sturdyref like any other peer fetching any other object, and a viewer that is
never handed one never opens a CapTP session at all.

The object answers **one verb**. `controls(inbox)` returns the current entries
and calls the viewer's inbox back when the list changes. It may return an empty
list, and usually will. That is the `watch(inbox)` shape `apps/rooms/lib/protocol.ts`
already uses for the room directory and `apps/tasks` uses for its board, so
change notification comes from a pattern the tree has proved, and revocation
needs no notification at all: a revoked control refuses when pressed, which is
machinery a capability system already has.

Each entry is `{ kind, label, cap, ...per-kind fields }`, where `cap` is a live
capability reference, `label` is display text, and `kind` is **action** (invoke
it) or **value** (invoke it with a value, and the entry carries the current
one). **There is no entry id**, deliberately: an id would be endpoint-chosen
while the viewer holds several endpoints, which is the collision the
[architecture rule](../../../.agents/rules/architecture.md)'s Names section
catalogs, and an endpoint reusing an id after removing an entry would let a
stale widget address a capability it was never given.

Three authority properties fall out and are the reason for the shape.

**The control surface never gets a port.** The trace feed is a loopback
websocket, which is ambient authority that ADR-0104 states outright is not an
authentication boundary. Replacing that is separate work. But the one surface
that can *change* an endpoint rather than describe it is capability-native from
its first line: holding the swissnum is holding the authority, and nothing else
confers it.

**Default is nothing.** A host mints no control capability unless configured
to, matching `ROOMS_VIZ_PORT`, where an absent variable leaves the tap cold. A
rooms server mints none. The common case of this feature is no control panel at
all, and that is success rather than an unfinished state — which is also why
"this endpoint offers no controls" has to be a state the viewer can show with
confidence, distinct from not connected, from connected and idle, and from
connected and unable to ask.

**A lying endpoint is confined to itself.** An endpoint can label a control
"Pause" and wire it to something else, and nothing prevents that. What bounds
it is that the label is display text and the capability is the authority: the
lie changes what a human believes they are invoking, never what the viewer is
able to invoke, because the viewer can only invoke capabilities the endpoint
handed it, all of which the endpoint already held over itself. A malicious
endpoint's best outcome is deceiving a human into telling it to do something it
could have done unprompted. This is ADR-0104's trust rule — an application's
claim is never protocol identity — applied to labels.

## Scope (what this does not decide)

- **None of this is built.** No endpoint publishes a control capability, no
  viewer dials one, and no code in the tree names the `controls` verb. The
  deletion this record accompanies removed a false implementation and did not
  add a true one.
- **No endpoint currently has a control worth offering.** A rooms server should
  mint none by design. `pancake griddle` is a simulator, so driving it affects
  nobody and it is the natural first publisher — but it is a CLI subcommand
  with no CapTP surface of its own today. Building the viewer half before an
  endpoint half would recreate exactly the defect being deleted.
- **The viewer is not a CapTP peer.** `apps/ocapnviz/deno.json` has no pancake
  dependency, ocapnviz sits outside the root Deno scope, and it builds with
  Vite while the rooms browser peer builds with `deno bundle` and serves its
  wasm from `zig-out/wasm/`. Teaching the viewer to hold a key means getting
  `@pancake/web` and a wasm artifact through a Vite build in an excluded scope,
  loaded lazily so a watch-only viewer never pays for it. That is the largest
  single piece of this feature and it is not started.
- **Capability-native observation is a separate, larger decision, and it is
  not made here.** Observing a host is authority, and a loopback port is
  ambient authority: everything on the machine that can reach the port gets
  the feed. The destination is a *viz capability* on the read side too — the
  trace stream published at its own name, fetched and subscribed to like any
  other object, so observing is attenuable and revocable and rides any
  transport. The tap stays the shared source; the WebSocket broadcast and that
  capability would be two sinks on it. Two rules are already known to fall out
  and are recorded so they are not rediscovered: the observer's own session is
  never traced, or observation feeds itself; and a relay is never a viz point,
  because byte-transparency is the relay contract and direct or encrypted
  sessions never show it anything. None of that is decided or built, and this
  record deliberately leaves the read path alone.
- **Richer trace facts are a third, separate decision.** What the timeline
  draws is topology: hosts, sessions, and the messages on them. What a session
  CARRIES — a peer's export and import tables, its outstanding answers, its
  gift registry — is reported by nothing. Those are per-session by
  construction, since an export position means nothing outside its session,
  while a host's objects and its capability registry are host-scope, so the
  two would belong to different panels. Adding them is a set of new facts on
  the same spine rather than a second stack, and it needs its own record
  before it needs code.
- **The wire shape above is a sketch, not a contract.** No constants module
  exists and none should until there is a second implementor; a constants file
  with one user is a constants file waiting to drift.

## Alternatives Considered

- **Keep the Pause/Resume/Step panel as scaffolding for this design.** Rejected
  because its shape is the opposite of this one: a fixed verb list the viewer
  already knew, aimed at whatever it happened to be connected to. Keeping it
  would preserve exactly the coupling this record exists to break. Its
  vocabulary also included `exit` — a viewer telling an endpoint to terminate —
  with nothing anywhere discussing what earns that.
- **A typed schema document the endpoint serves.** Rejected: it makes the
  viewer a schema interpreter and still leaves the authority question open,
  because a schema describes controls rather than conferring them.
- **Probe and degrade — try a verb, hide the button if it fails.** Rejected: it
  is guessing dressed as discovery, and it cannot distinguish "not offered"
  from "offered and broken", which is the distinction the empty case needs.
- **Carry controls on the trace stream as a return channel.** Rejected: it
  destroys ADR-0104's property that a producer's socket carries nothing back,
  which is what stops telemetry becoming a channel between peers.
- **A control panel the viewer publishes and the endpoint fills in.** Rejected:
  it inverts the grant, handing the endpoint authority over the viewer's
  interface rather than the viewer a bounded reference.

## Consequences

The deletion this record accompanies removed `apps/ocapnviz/src/ui/DriveSimPanel.tsx`,
the `ControlCommand` and `ControlAck` types, `LiveFeed.send`, `LiveFeed.onAck`
and their ack plumbing, the `sendCommand` / `lastAck` path through
`state/hooks.ts` and `App.tsx`, and the dead base-kind ingestion arm with the
`BaseTimelineEvent` fields that served only it. `LiveFeed` is now receive-only
in code as well as in practice: it never writes to its socket.

When this record is implemented, the endpoint half is built before the viewer
half, and the proof is a headless in-tree scenario with no browser and no relay:
a native peer enlivens the control sturdyref, reads the entries, invokes one,
and observes the effect. The empty case is proved in the same step, because
"offers nothing" is the default and a default nobody tests is a default nobody
has. The viewer half then earns a browser proof alongside the `rooms-web-*`
family, asserting that a real tab dials a control endpoint, renders what it was
handed, invokes one entry, and shows no panel for a producer it holds no key to.

The viewer will cap what it renders — a maximum entry count, a maximum label
length, bounded options per entry — because it is talking to endpoints its
operator does not necessarily run. The endpoint already takes that posture with
its per-producer row cap.

## Notes

- [ADR-0104](ADR-0104-live-trace-convergence.md) owns the trace convergence this
  record leaves untouched, and supplies the trust rule its label argument
  applies.
- [ADR-0105](ADR-0105-connection-scoped-durable-authentication.md) owns what a
  connection can prove about a peer, which is what a control endpoint's
  designator is worth when a viewer attributes a label to it.
