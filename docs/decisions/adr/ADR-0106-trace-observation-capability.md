---
id: ADR-0106
status: accepted
date: 2026-08-04
tags: [observability, ocapnviz, capability, rooms, authority]
decision: "Live ocapnviz observation is an OCapN capability: the convergence endpoint publishes a read-only trace object at an unguessable sturdyref, the browser enlivens it and grants an inbox capability, and bounded canonical trace records arrive through CapTP. Telemetry ingestion remains a one-way adapter. Observation and control are separate grants. This record accepts observation without inventing controls no endpoint offers."
supersedes: []
superseded_by: []
amends: [ADR-0104]
amended_by: [ADR-0120]
---

# ADR-0106 Trace observation capability

## Status

Accepted. The capability endpoint, browser peer, bounded subscription
protocol, wasm packaging, and production-bundle Chromium proof are
implemented.

## Context

[ADR-0104](ADR-0104-live-trace-convergence.md) established a convergence
endpoint because room activity is observed by several independent producers.
That endpoint assigns producer scopes, sequence numbers, an epoch, and arrival
times. Those facts have one authority. A viewer cannot reconstruct them by
dialing each producer.

A loopback WebSocket that streams traces to every process that can reach it
makes the port the only permission to observe. Observation is authority: a room
topology reveals peers, relationships, and message timing. An ambient port
cannot express attenuation, delegation, or revocation.

No endpoint implements Pause, Resume, or Step verbs, so the UI offers none. A
read grant and a mutation grant are different authority.

## Decision

**Live observation is an OCapN capability.** The convergence endpoint hosts a
read-only trace object at an unguessable swissnum and announces its ordinary
sturdyref. ocapnviz parses that sturdyref, lazily loads the browser wasm Host,
dials its locator, enlivens the trace object, hosts an inbox, and calls:

```text
trace.subscribe(inbox)
inbox.record(canonical_json_trace_line)
```

The sturdyref, not the WebSocket address, is the observation grant. WebSocket is
the byte channel of the TCP browser transport, and the capability protocol can
ride another transport unchanged.

The observer session uses the v1.0 interop profile. It is a generic ocapnviz
capability protocol, not a Rooms peer, and does not use the private Rooms
profile. The endpoint, production browser, and browser-shaped tests all use the
binding's v1.0 floor.

The endpoint remains the sole authority for producer scope, `seq`, `epoch`,
arrival time, current live rows, and replay. Canonical bounded JSON trace lines
remain the rooms/ocapnviz application schema for both live and offline data.
JSON carries observations, not authority. Typed OCapN values would add a second
schema and remove no ambiguity.

### Subscription contract

- `subscribe` accepts exactly one inbox capability and requires an active
  CapTP session.
- A session has at most one subscription. Calling `subscribe` again replaces
  that session's prior inbox. It does not create a second delivery stream.
- A new subscription first receives an authoritative replay of every current
  row followed by one replay-complete record. Live records are queued after
  that boundary.
- Replay records are snapshots, not history. On replay completion the viewer
  removes observations absent from the snapshot, so outage recovery converges.
- Epoch changes reset sequence comparison. Within one epoch, duplicate or
  older non-replay records are ignored.
- Closing either CapTP session ends its subscription. Closing the endpoint
  closes every observer session and releases the trace Host. Withdrawing or
  replacing the sturdyref is ordinary capability revocation.

A record is at most 1 MiB. The
endpoint admits at most 64 subscribers. Each subscriber may queue at most 256
records and 8 MiB. Exceeding any queue bound closes that observer's session
instead of dropping records silently. The viewer reconnects and obtains a new
authoritative replay. The room server never stores for an unbounded observer.

The CapTP sessions that deliver observation are not room activity. The
endpoint excludes its observer sessions from the trace, since observing the
trace would otherwise change it.

### Ingestion and control

`/publish` is a one-way JSON WebSocket telemetry adapter. Producers send
bounded observations and receive no commands or peer traffic. It is not the
viewer protocol and confers no observation capability.

Observation and control are separate grants. This record defines only
observation. An endpoint may publish control capabilities later, and a viewer
must receive those references separately and render only the operations they
confer. No fixed command vocabulary, probe-based discovery, or return channel
on `/publish` is permitted. No endpoint offers a control today, so the viewer
shows none.

Offline file and fixture modes do not initialize wasm. Live mode pays for one
browser Host only when the operator supplies a sturdyref.

## Consequences

- ocapnviz is a browser OCapN peer in Live mode: it hosts an inbox,
  receives calls, and owns peer/session teardown.
- A trace URL is not a public API. The rooms server announces
  `ROOMS-TRACE-LISTENING <sturdyref>`, and the UI accepts that sturdyref.
- Reconnect is loss recovery, not best-effort continuation. Queue pressure and
  connection loss both lead to replay from the endpoint's current authority.
- The wasm artifact is a production ocapnviz dependency and is copied into the
  Vite output. Unit tests using a mocked feed do not substitute for the
  production browser proof.
- The rooms server is a convergence point for observations and does not broker
  room capability traffic. Direct messages still travel directly between
  their peers.
- Richer per-session protocol facts and any mutation controls require separate
  authority and evidence. They are not implied by access to the topology trace.

## Alternatives Considered

- **Keep viewer observation as raw WebSocket broadcast.** Rejected because
  reachability to a port is ambient authority and cannot be delegated or revoked
  as an object reference.
- **Dial every producer directly.** Rejected because producer scope, ordering,
  and replay would acquire several competing authorities, and producers would
  become observer-facing services.
- **Carry trace records as typed OCapN argument structures.** Rejected: canonical
  bounded JSON serves live and offline modes and carries no authority, and a
  second representation would drift.
- **Drop records for slow subscribers.** Rejected because the viewer would stay
  connected with a permanently incomplete topology. Closing and replaying is
  bounded and convergent.
- **Retain fixed Pause/Resume/Step buttons.** Rejected because no capability
  grants those operations and no endpoint implements them.
- **Carry control commands back through `/publish`.** Rejected because it
  turns one-way telemetry into ambient mutation authority and a peer broker.

## Evidence

- Rooms endpoint tests cover durable publication, replay ordering, duplicate
  subscription replacement, overflow closure, teardown, and observer-session
  exclusion.
- ocapnviz tests cover sturdyref validation, lazy wasm startup, inbox delivery,
  replay reconciliation, reconnect, and peer lifetime.
- `zig build ocapnviz-check` builds the production Vite bundle and requires
  `dist/glowcap_host.wasm`.
- `zig build ocapnviz-live-browser` drives a real Chromium tab against the
  production bundle. It initializes wasm, dials the announced sturdyref,
  renders a fresh replay and a subsequent live record, and asserts that the
  observer session is absent from the topology.

## Notes

- [ADR-0104](ADR-0104-live-trace-convergence.md) is the authority for
  producer convergence and the trace schema. This record amends its viewer
  delivery boundary.
- [ADR-0105](ADR-0105-connection-scoped-durable-authentication.md) owns what a
  transport proves about the peer behind a sturdyref.
