---
id: ADR-0120
status: accepted
date: 2026-08-18
tags: [observability, ocapnviz, capability, rooms, authority]
decision: "The rooms live-trace endpoint admits no socket on reachability: enabling it mints one persisted trace swiss that every connect — producer and viewer alike — presents as the `cap` query parameter or is closed with a typed refusal. The same swiss names the durable trace publication, so the announced sturdyref stays the whole viewing grant, the swiss prints as the ROOMS-TRACE operator-capability line, and a browser tab's trace publishing arms only while it holds it."
supersedes: []
superseded_by: []
amends: [ADR-0104, ADR-0106]
amended_by: []
---

# ADR-0120 Trace endpoint capability admission

## Context

[ADR-0106](ADR-0106-trace-observation-capability.md) made live observation an OCapN
capability: a viewer subscribes only by enlivening the announced sturdyref.
It left `/publish` as "a one-way JSON WebSocket telemetry adapter", which kept
reachability as the whole authority to write into the timeline, and the
socket on either path could be held open by anyone who could reach the port.
Writing is the wider hole: a reachable process could invent sessions, labels,
and closures for every viewer. Meanwhile the rooms app already had the shape
for operator authority — the flag-minted, `GLOWCAP_ROOMS_STATE`-persisted operations
swiss taken in the web UI through the toggle-is-the-capability flow.

## Decision

Enabling the endpoint (`--trace`, or its env twin `GLOWCAP_ROOMS_TRACE=1`;
the `GLOWCAP_ROOMS_TRACE_PORT` override moves only the port and enables
nothing) mints the trace capability: one swiss
from the same `persistentSwiss` machinery as the other operator capabilities,
persisted as `GLOWCAP_ROOMS_STATE/trace` and printed as a `ROOMS-TRACE` token line. With
the endpoint off, nothing is minted, persisted, or published.

The host endpoint (`apps/rooms/rust/services/src/server/operations/trace.rs`) takes that swiss and refuses every
socket that does not present it as the `cap` query parameter, comparing in
constant time and closing with code 4403 and a readable reason after the
upgrade, so a WebSocket client sees why. A refused socket is never a producer
and never a viewer: no handler is installed, nothing it sends is parsed. An
admitted producer hears one endpoint-authored `trace.publish-ready` mark — the
positive admission signal that makes a client's take a deterministic round
trip — and nothing else, keeping the one-way posture.

The trace object is published under the same swiss (`publishGiftable` rather
than a separately minted durable name), so the `ROOMS-TRACE-LISTENING` sturdyref
remains the complete viewing grant: its swissnum admits the socket and
enlivens the trace. ocapnviz presents it from the sturdyref it already holds.
The rooms web tab arms its publishing only while the reader holds the swiss,
through a third Advanced toggle with the shared take-and-remember flow, keyed
by the endpoint URL rather than a directory because that is where the swiss is
redeemed.

## Scope (what this does not decide)

One swiss is both read and write authority, and it is presented per socket
rather than per session. Splitting producer from viewer authority — and
handing each socket a capability object instead of a bearer query parameter —
is the planned next step and is not designed here.

## Alternatives Considered

- **First-frame hello instead of a query parameter**: rejected because it
  adds per-socket protocol state to both paths for the same secret, and the
  refusal stops being immediate at connect.
- **A second flag for the capability**: rejected because an enabled endpoint
  with an optional guard is exactly the ambient door this closes; the knob
  that creates the endpoint mints its authority.
- **A separate viewer swiss beside the sturdyref**: rejected because the
  sturdyref already carries an unguessable name; a second secret for the same
  grant gives one authority two spellings.

## Consequences

- Reachability to the trace port reads and writes nothing; the announced
  sturdyref and the `ROOMS-TRACE` line are the only ways in, and both are
  operator-distributed.
- Producers must hold the swiss: the web tab's toggle, the demo and proof
  harnesses' seeded memory, and the server's own in-process sink (which never
  crosses a socket) are the writers.
- `ROOMS-TRACE` joins the operator-capability table in the serving block, and a
  supervised respawn republishes the same swiss.

## Evidence

- `apps/rooms/test/trace/cap_test.ts`: the write refusal (the headline), the
  viewer refusal, the admission mark, trace-off minting nothing with a stale
  swiss answering nothing, and the announcement carrying the persisted swiss.
- `apps/rooms/test/trace/endpoint_test.ts`: the endpoint's merged-feed contracts,
  unchanged, with every socket presenting the capability.
- `zig build rooms-web-page`: the third toggle's take flow, three-pane tab
  bar, and drop-erases in a real Chromium.
