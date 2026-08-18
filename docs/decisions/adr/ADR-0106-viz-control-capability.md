---
id: ADR-0106
status: accepted
date: 2026-08-04
tags: [observability, ocapnviz, capability, rooms, authority]
decision: "Live ocapnviz observation is an OCapN capability: the convergence endpoint publishes a read-only trace object at an unguessable sturdyref, the browser enlivens it and grants an inbox capability, and bounded canonical trace records arrive through CapTP. Telemetry ingestion remains a one-way adapter. Observation and control are separate grants; this record accepts observation without inventing controls no endpoint offers."
supersedes: []
superseded_by: []
amends: [ADR-0104]
amended_by: [ADR-0120]
---

# ADR-0106 The viz capability

## Status

Accepted. The capability endpoint, browser peer, bounded subscription
protocol, wasm packaging, and production-bundle Chromium proof are
implemented.

This record began as a proposal for a control capability while leaving
observation on an ambient WebSocket. No part of that proposal had shipped.
Implementation scrutiny found the more fundamental authority error in the
read path, so this record decides the implemented viz capability architecture
instead of preserving an unimplemented draft.

## Context

[ADR-0104](ADR-0104-live-trace-convergence.md) established a convergence
endpoint because room activity is observed by several independent producers.
That endpoint assigns producer scopes, sequence numbers, an epoch, and arrival
times. Those facts have one authority; a viewer cannot reconstruct them by
dialing each producer.

The original Live mode exposed the resulting stream to every process that
could reach a loopback WebSocket. That transport moved trace bytes, but the
port was also the only thing standing in for permission to observe them.
Observation is authority: a room topology reveals peers, relationships, and
message timing. An ambient port cannot express attenuation, delegation, or
revocation.

The old UI also contained Pause, Resume, and Step controls. No endpoint
implemented those verbs, so the controls were removed rather than retained as
false affordances. A read grant and a mutation grant are different authority;
fixing observation does not justify recreating controls.

## Decision

**Live observation is an OCapN capability.** The convergence endpoint hosts a
read-only trace object at an unguessable swissnum and announces its ordinary
sturdyref. ocapnviz parses that sturdyref, lazily loads the browser wasm Host,
dials its locator, enlivens the trace object, hosts an inbox, and calls:

```text
trace.subscribe(inbox)
inbox.record(canonical_json_trace_line)
```

The sturdyref, not the WebSocket address, is the observation grant. WebSocket
remains only the byte channel used by the current TCP browser transport. The
same capability protocol can ride another transport without changing the
application contract.

The observer session uses the v1.0 interop profile. It is a generic ocapnviz
capability protocol, not a Rooms peer and not a consumer of the private Rooms
profile. The endpoint, production browser, and browser-shaped tests therefore
all use the binding's explicit v1.0 floor.

The endpoint remains the sole authority for producer scope, `seq`, `epoch`,
arrival time, current live rows, and replay. Canonical bounded JSON trace lines
remain the rooms/ocapnviz application schema for both live and offline data.
JSON carries observations, not authority; replacing it with typed OCapN values
would add a second schema without removing a current ambiguity.

### Subscription contract

- `subscribe` accepts exactly one inbox capability and requires an active
  CapTP session.
- A session has at most one subscription. Calling `subscribe` again replaces
  that session's prior inbox; it does not create a second delivery stream.
- A new subscription first receives an authoritative replay of every current
  row followed by one replay-complete record. Live records are queued after
  that boundary.
- Replay records are snapshots, not history. On replay completion the viewer
  removes observations absent from the snapshot, so outage recovery converges
  rather than merely appending.
- Epoch changes reset sequence comparison. Within one epoch, duplicate or
  older non-replay records are ignored.
- Closing either CapTP session ends its subscription. Closing the endpoint
  closes every observer session and releases the trace Host. Withdrawing or
  replacing the sturdyref is ordinary capability revocation.

Every bound is part of the protocol posture. A record is at most 1 MiB. The
endpoint admits at most 64 subscribers. Each subscriber may queue at most 256
records and 8 MiB. Exceeding any queue bound closes that observer's session
instead of dropping records silently; the viewer reconnects and obtains a new
authoritative replay. An unbounded observer is not allowed to become storage
owned by the room server.

The CapTP sessions used to deliver observation are implementation machinery,
not room activity. The endpoint excludes its own observer sessions from the
trace, or observing the trace would recursively change it.

### Ingestion and control

`/publish` remains a one-way JSON WebSocket telemetry adapter. Producers may
send bounded observations and receive no commands or peer traffic. It is not
the viewer protocol and confers no observation capability.

Observation and control are separate grants. This record defines and accepts
only observation. A future endpoint may publish control capabilities, but a
viewer must receive those references separately and render only operations
they confer. No fixed command vocabulary, probe-based discovery, or return
channel on `/publish` is permitted. Today no endpoint offers a control worth
granting, and showing no control surface is the complete behavior.

Offline file and fixture modes do not initialize wasm. Live mode pays for one
browser Host only when the operator supplies a sturdyref.

## Consequences

- ocapnviz is a real browser OCapN peer in Live mode: it hosts an inbox,
  receives calls, and owns peer/session teardown.
- A trace URL is no longer a public API. The rooms server announces
  `ROOMS-VIZ-LISTENING <sturdyref>`, and the UI accepts that sturdyref.
- Reconnect is loss recovery, not best-effort continuation. Queue pressure and
  connection loss both lead to replay from the endpoint's current authority.
- The wasm artifact is a production ocapnviz dependency and is copied into the
  Vite output. Unit tests using a mocked feed do not substitute for the
  production browser proof.
- The rooms server remains a convergence point for observations, not a broker
  for room capability traffic. Direct messages still travel directly between
  their peers.
- Richer per-session protocol facts and any mutation controls require separate
  authority and evidence. They are not implied by access to the topology trace.

## Alternatives Considered

- **Keep viewer observation as raw WebSocket broadcast.** Rejected because
  reachability to a port is ambient authority and cannot be delegated or
  revoked as an object reference.
- **Dial every producer directly.** Rejected because producer scope, ordering,
  and replay would acquire several competing authorities, and producers would
  become observer-facing services.
- **Carry trace records as typed OCapN argument structures.** Rejected for this
  surface: canonical bounded JSON already serves live and offline modes and
  does not carry authority. A second representation would create drift.
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
  replay reconciliation, reconnect, and exact peer lifetime.
- `zig build ocapnviz-check` builds the production Vite bundle and requires
  `dist/pancake_host.wasm`.
- `zig build ocapnviz-live-browser` drives a real Chromium tab against the
  production bundle. It initializes wasm, dials the announced sturdyref,
  renders a fresh replay and a subsequent live record, and asserts that the
  observer session is absent from the topology.

## Notes

- [ADR-0104](ADR-0104-live-trace-convergence.md) remains the authority for
  producer convergence and the trace schema. This record amends its viewer
  delivery boundary.
- [ADR-0105](ADR-0105-connection-scoped-durable-authentication.md) owns what a
  transport proves about the peer behind a sturdyref.
