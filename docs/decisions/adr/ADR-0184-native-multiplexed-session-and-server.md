---
id: ADR-0184
status: accepted
date: 2026-10-03
tags: [driver, transport, ownership, iroh]
decision: "Native Session and Server use the shared provider registry and runtime-owned listeners. The native iroh adapter owns transport state for both Zig and C."
supersedes: []
superseded_by: []
amends: [ADR-0081, ADR-0090, ADR-0112]
amended_by: []
---

# ADR-0184 Native multiplexed Session and Server

## Context

The runtime admits stream and multiplexed providers, but native convenience
constructors accepted stream netlayers and transferred listeners out of runtime
ownership. Iroh's managed connection map and listener state lived in C adapter
storage. Native convenience support needs the same lifecycle without a second
transport runtime or acceptance path.

## Decision

`HostRuntime.initProviders`, `driver.connectProviders` and
`driver.listenProviders` register borrowed stream or multiplexed contexts.
The contexts remain stable until all associated runtime leases have retired.
The optional iroh module supplies `iroh.MultiplexedAdapter`, which borrows one
Resident exclusively for managed readiness and owns connection identity,
failure custody and listener metadata. C projects that state. An adapter never
owns the endpoint, and teardown closes unclaimed connection handles before the
endpoint is released.

Every native Server activates a runtime-owned listener. It reserves a ring of
Session pointers once at construction. Finished sessions and pending handshake
reservations share `max_pending_opens`. Ordinary pressure refuses an arrival
without failing the Host. Accepted sessions remain unattended until their
caller publishes roots and drives reception. Arrival failure notification
preserves blocking accept's timeout and failure result without terminating
sibling sessions. When another session or aggregate runtime pump serves a
yielded Session, `Session.attend` marks the end of its setup explicitly. Step,
serve and blocking reply operations do so implicitly.

Server close seals admission, cancels unfinished handshakes, joins physical
listener retirement and disposes queued sessions. Yielded sessions retain their
own runtime lease. The heap-stable Server remains the observer context through
that barrier, so it needs no separately allocated admission owner. Close from
a callback or the wrong thread refuses before mutation. Deinit preserves the
handle on that refusal, matching Session's ownership discipline. A shared step
goal checks listener retirement or consumer readiness before the runtime parks.
Onion and keyed-relay listener projections expose their existing descriptors to
that same poll. Relay probes clear idle wake hints and retain readable arrivals
until accept claims them. Locator replacement follows provider canonicalization. TCP's
direct-address hints retain its existing literal-address grammar.

The sidecar owns a bounded raw accept queue and an admission generation under
one mutex. Stop detaches that queue without creating connection handles or
reader/writer tasks. A restarted listener rejects old establishment completions.
Partial claims keep accept readiness live until the queue is empty. Existing
claimed connections are independent of admission.

Dial admission pressure belongs to the shared `DialError.WouldBlock` retry
axis. Native and C projections retain that classification, and `DialRetry`
retries it only within the caller's attempt bound. It admits no operation and
creates no reconnection policy inside the transport.

## Alternatives considered

- A native stream/resident Server union would duplicate lifecycle and locator
  policy already owned by the runtime.
- Keeping a C connection map beside a native map would create two authorities
  for stable connection identity and transport failure custody.
- Discarding accepted handles in a loop can be replenished indefinitely and
  creates reader/writer work solely to throw it away.
- A separately reference-counted admission owner is unnecessary when native
  close joins retirement and refuses reentrant destruction before mutation.

## Evidence and scope

`zig build iroh-managed`, also included in `iroh-driver-provider`, proves native
dial, authenticated identity, named fetch and an exact method reply after
Server destruction over real endpoints. Scripted resident tests cover map OOM,
failure claiming, stale close, advertisement refusal, admission teardown and
bounded readiness draining. Native Server tests join pending listener stops
and retain failures delivered during that join. Reply waits retire stack
listeners even when attendance fails. Native and C tests retain dial pressure
classification, and retry tests bound repeated pressure.
The relay listener proof covers idle wake clearing, repeated acceptable probes
and replacement registration after claim.
The sidecar tests cover bounded pressure, generation refusal and partial claim
readiness. Stream driver tests retain the blocking accept timeout contract.

This decision adds no wire format, protocol semantics or signaling authority.
WebRTC's managed signaling adapter remains unfinished. Direct local endpoints
do not establish two-NAT or public-relay reachability evidence.
