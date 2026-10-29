---
type: living
description: The known limits that can change a deployment or API choice.
sources: []
---

# Known limitations

Pin a commit. APIs, ABIs, and prerelease store formats have no compatibility
guarantee. [What ships](shipped.md) lists features, [stability](stability.md)
records test coverage, and the [roadmap](roadmap.md) owns work to close gaps.
A limitation here describes current behavior, not acceptance of it as the goal.

## Protocol draft coverage

`glowcap-next` retains the shared four-field hello and crypto representations,
so it does not provide complete current-draft conformance. The
[conformance manifest](ocapn-conformance.md) names the deferred sections.
The [crypto transition](roadmap.md#waiting-on-upstream) waits on a compatible
specification and Goblins release.

## Transports and peer identity

- **`tcp`, `keyed-tcp`, and `keyed-relay` are cleartext and unauthenticated.**
  A key designator alone proves no possession of that key. WSS to a relay
  does not protect CapTP from the relay operator. Use `noise-tcp`,
  `noise-relay`, iroh, or WebRTC with trusted signaling for deployment.
- **Address locators prove no identity.** On `tcp` and `onion`, a peer claiming
  the address of an outstanding dial can win its crossed-connection tiebreak.
  An open session is protected from that claim. Address aliases remain
  separate peers, while a channel-proved durable key permits session replacement.
- **A proved key does not identify a person.** Human identity and bot resistance
  belong to the application ([identity](https://glowcap.org/identity/)).
- **`inproc` is for tests.** Its unbounded, blocking pipes do not model production
  backpressure or scale.
- **Zig onion clients accept TCP Tor endpoints only.** Unix-socket SOCKS and
  control endpoints need a binding. This adapter gap is
  [roadmap work](roadmap.md#what-starts-next).
- **Onion negotiation preserves Goblins compatibility.** Versions above `1.0`
  are offered only to a peer known to be glowcap. Pinned Goblins refuses
  hinted onion locators ([ADR-0042](decisions/adr/ADR-0042-onion-interoperability.md)).
- **WebRTC needs configured signaling.** Its Rust provider and iroh's Rust
  stack are dependencies, not Zig implementations. A silent iroh peer is
  detected after its configured idle timeout. Shortening it costs idle traffic.
  [Transport setup](../bindings/README.md#transports) gives the options.

## Invocation shape

Actor APIs read a leading positional symbol as the method selector. A first
positional symbol is therefore indistinguishable from a selector on the wire.
Absent and empty selectors remain distinct through forwarding and every
binding ([invocation contract](../bindings/README.md#invocation-shape)).

## Runtime and scale

- **Bun cannot host the driver loop.** Its synchronous FFI would park JavaScript.
  Use Deno for those APIs pending the
  [runtime decision](roadmap.md#waiting-on-you).
- **A Vat runs one turn at a time.** A blocking handler stalls its Host.
  Defer its answer and settle on the owning thread. Only plain data crosses
  worker threads ([actor execution](decisions/adr/ADR-0014-actor-execution-and-lifetime.md)).
- **Admission and waits are explicit.** Opening sessions have bounded capacity,
  and callers may choose unbounded handshake or settlement waits.
  [Resource options](architecture.md#resource-knobs) own the defaults.
- **A driver permits one listener per transport.** The relay can host keyed or
  Noise traffic, but not both at once, because rendezvous queues by designator.
- **Backend reporting is incomplete.** `driver.HostRuntime` does not expose the
  Linux backend selection available from `net.tcpBackendStatus`.
  [Adapter work](roadmap.md#what-starts-next) owns the missing projection.
- **Driver readiness descriptors require Linux or Darwin.** Other platforms
  retain stepping APIs. Windows has no implementation. Platform work and
  verification are [tracked separately](roadmap.md#waiting-on-hardware-or-a-hostname).
- **A plain Host needs saved publication entropy.** Republish the same
  <!-- value ../src/ocapn/session/references/bootstrap.zig durable_swiss_entropy_len -->16<!-- /value --> bytes after restart to preserve a durable name.
  [Loam publications](loam/publications.md) store names for you.
- **Bindings have different frame costs.** TypeScript, Python, and Racket copy
  outbound bytes before asynchronous writes. Rust retains the frame.
  Custom codec registration is Zig-only. C and bindings select built-in codecs.

## API gaps

### Loam storage

- **A lost reply does not mean an aborted change.** Pending calls and replies
  are not durable. Behaviors perform no outside effects, and applications own
  durable effect receipts and restart recovery
  ([C and Rust](loam/c-and-rust.md#work-after-a-receipt-commits)).
- **An unknown commit outcome blocks other work** until
  [recovery](loam/store.md#when-a-writes-outcome-is-unknown) establishes it.
- **One process owns a store.** Growth and each transaction's work are bounded.
  Engine page caches sit outside Store memory limits. The
  [Store guide](loam/store.md) owns sizing, reads, and close requirements.
- **Collection needs spare space and bounded work.** It can refuse new
  retention, and durable names keep index reservations after collection
  ([collection](loam/collection.md#bounds)).
- **Foreign APIs cover one managed resource with registered content graphs.**
  C, Rust, and [IndexedDB](loam/browser.md) do not expose resource-tree editing
  or owner administration. The
  [C/Rust guide](loam/c-and-rust.md#registered-content-graphs) defines supported
  graphs. The [roadmap](roadmap.md#what-starts-next) owns extending that surface
  and integrating recursive Rooms resources.

### Managed access

- **The standalone in-memory graph and grant ledger reserve capacity up front.**
  They have no restore path and require fresh identities when recreated.
  [Record-backed owners](loam/access.md#durable-owner-operations) support persistence
  and loading on demand. Stored identities are not reused, while
  [cleanup](loam/access.md#bounded-owner-cleanup) can reclaim records.
- **Receipts and change history are finite.** An expired receipt refuses a retry.
  Observation resynchronizes after history expires
  ([retry and observation contracts](loam/access.md)).
- **Policy uses a bounded vocabulary.** Permissions, numeric bounds, and resource
  kinds must cover each effect. An earlier evaluation never authorizes a later
  effect ([policy support](loam/access.md#policy-and-interface-support)).
- **Descriptions and live fields have limited lifetimes.** `describe-access`
  returns a snapshot without controls or events. A live capability field refuses
  after its hosting lifetime ends ([reference fields](loam/c-and-rust.md#reference-fields)).
- **Local receipts do not create a distributed transaction.** A remote
  publication remains under its remote owner's lifetime. Reads, cache leases,
  permanent-name costs, and close rules are specified in the
  [access storage guide](loam/access-storage.md).

### Rooms

[Operating Rooms](../apps/rooms/operating.md#known-limitations) owns application
limits. The [session guide](rooms/session.md) covers observation and file access.
An inbox gap needs explicit recovery. DM file bytes can expire or disappear
when the sender's session ends, even when the message remains.

### Host and ABI

- **Pending and local promises have API gaps.** Forwarding to a pending local
  promise can refuse with `PromisePending`. A local-only vow has no capability
  form and refuses conversion with `SessionlessVow`. These are part of the
  [promise work](roadmap.md#what-starts-next).
- **Libc-linked shared archives remain mapped until process exit** so detached
  workers cannot return into unloaded code
  ([ADR-0024](decisions/adr/ADR-0024-transport-provider-and-abi-contracts.md)).
- **Rust recovery requires its owning thread.** Exiting that thread with refused
  C releases pending retains callbacks and Rust owners for the process lifetime.
  Finish recovery before thread exit. The
  [adapter audit](roadmap.md#what-starts-next) must establish a safe terminal outcome.
- **An accepted plain-TCP session cannot prove a sturdyref's peer.** Enlivening
  refuses unless `assertion_only` is explicit, and then reports asserted identity.
  Enlivening also does not prove equality with a capability already held.

## Protocol and interop

- **Locators permit at most <!-- value ../src/ocapn/model/hints.zig max_count -->32<!-- /value --> hints.**
  Unknown names within that resource bound are preserved and ignored.
- **Profiles and negotiated features constrain routing.** Only the Node selects
  a route bundle. A physical-session open refuses one, and a give falls back to
  a single claimed location unless both sessions negotiated multi-location
  ([multi-home peers](https://glowcap.org/multihome/)).
- **Forwarded answer references are session-relative.** Re-sending the partner's
  answer reference in a call argument or reply breaks with a typed reason.
  The [upstream question](upstream-watch.md#answer-references-outside-target-position)
  owns the missing wire representation.
- **Projected remote pipelines can break across sessions.** When a projected
  promise settles on another session, its partner's queued call breaks even
  though listening can redeem the handoff. Local application calls follow the
  capability. This needs the [promise work](roadmap.md#what-starts-next).
- **Published resolutions retain the imports they name** until the partner
  releases the answer, subject to retained-answer limits
  ([ADR-0070](decisions/adr/ADR-0070-stored-resolutions-hold-imports.md)).
- **OCapN Null is absent, and Goblins can reject independent receivers' handoffs.**
  [Upstream watch](upstream-watch.md) records the specification and peer dependencies.
  Unknown Syrup records retain their tags. Cap'n Proto interoperates only between
  glowcap peers. Handoff signatures use Syrup even on those sessions.
- **Unproved peer identity cannot establish equality across sessions.** Matching
  locators alone do not make two remote targets the same capability.

## Browser reachability

- **A browser opens no listening socket.** It needs a relay or WebRTC signaling.
  An iroh gateway can read traffic and vouch for the peer, while `noise-relay`
  seals the stream end to end ([relay trust](https://glowcap.org/relay/)).
- **STUN does not cover every network.** Symmetric NATs and strict firewalls may
  require TURN. Rooms needs a configured credential issuer, and Zig WebRTC
  applications own refresh. Standalone sessions must configure their relay or
  WebRTC route ([session connectivity](../apps/rooms/operating.md)).
- **Deployment evidence is incomplete.** Public-certificate WSS, separate-NAT
  reachability, live onion scale, non-Linux runtimes, and several storage and
  performance cases lack evidence. [Stability](stability.md) and the
  [measurement contract](loam/access-storage.md#performance-contract-and-measurements)
  specify coverage. The [roadmap](roadmap.md) schedules extensions.
