# Known limitations

These are the limits that can change a deployment or API choice. This page is
not a backlog or a design history. [What ships](shipped.md) is the feature
inventory, [stability](stability.md) says how each surface is tested, and the
[roadmap](roadmap.md) owns future work.

## Transports and peer identity

- **Plain TCP and `keyed-tcp` are cleartext.** A locator's designator is the
  value that names the peer the dialer intends to reach. `keyed-tcp` binds that
  advertised identity to the CapTP handshake key, but it does not encrypt
  frames. Use iroh or WebRTC when the channel must be confidential.
- **An address is not an identity.** On plain TCP, the crossed-connection
  tiebreak trusts the location each peer declares. A peer that can connect and
  claim an address you are dialing can make your outgoing session lose that
  tiebreak. A key-designator transport avoids this because the identity a hello
  claims must be proved before the session opens, by the transport on iroh and
  WebRTC or by the hello's credential on `keyed-tcp` and keyed-relay. Only a
  proved identity can collapse a session, so an unproved claim cannot condemn
  one.
- **Two sessions to one peer stay open on an address transport.** `127.0.0.1`
  and `[::1]` are different designators, and neither is an identity pancake
  will act on, so nothing joins the two sessions. A key-designator transport
  recognises the peer by the durable name its hello proves and keeps one.
- **`inproc` is a test transport.** Its unbounded pipes block the reading
  thread, so it is not a production or load-test substitute.
- **iroh reachability is not fully exercised in CI.** The loop checks
  multiplexing, and opt-in checks cover discovery and relay use from one host.
  They do not cover hole-punching between separate NATs.
  `discovery_no_relay` has no green check because it needs a publishable direct
  address. Goblins ships no iroh netlayer, so there is no live
  Goblins-over-iroh check.
- **A `webrtc` dial needs configured signaling authority.** On the TypeScript
  stack, a host configured with `Host.setSignaling` dials a bare `webrtc`
  locator: the dial executor runs the offer, answer, and candidate exchange
  and holds the keyed session over the opened DataChannel. Without that
  authority the dial refuses. On the native side the same posture holds: the
  completion backend dials through a configured `SignalingAuthority` and
  adopts signaled peers into the generic Host.

The iroh and WebRTC transports rely on their existing sidecars; pancake does
not ship a native Zig QUIC or WebRTC stack.

## Runtime and scale

- **A Host's actor runtime (its Vat) is single-threaded and non-preemptive.** A
  hosted behavior runs synchronously to the end of its turn. A slow or blocking
  handler therefore stalls every session adapter (Port) sharing that Host. Keep
  handlers bounded. Separate Hosts provide scheduling isolation by also
  separating network identity and actor graphs; when those must remain shared,
  move blocking work out of the behavior callback. The actor layer's mechanism
  for that is the resolver vow
  ([ADR-0102](decisions/adr/ADR-0102-off-turn-settlement.md)): a behavior
  defers its answer with `Turn.forwardVow` and the work's completion settles
  it later through `Vat.fulfillVow` or `Vat.breakVow`, on the owning thread.
  A byte-fed embedder has the same seam over the C surface
  (`pancake_host_spawn_resolver` and its settle verbs). A TypeScript or
  Python behavior that returns a promise defers this way automatically, and
  the Rust and Racket bindings expose the resolver pair directly. A native
  worker thread hands its settle back through `driver.SettleMailbox`: the
  post wakes the owning thread's wait — `PollHost` polls the mailbox's fd
  beside its wires, and the completion loop arms a recv on it — and the
  settle applies there. Off-thread settles carry plain data only; a
  capability never crosses threads.
- **The 500,000-session target has not been proved under live socket load.**
  Checked budgets hold the warmed protocol core near 2 KiB per session, and the
  loop checks serve many connections, but neither is a 500,000-connection run.
  [The ladder](ladder.md) carries the measured budgets.
- **The simplest blocking pump serves one connection on one fiber.** Use the
  TCP or iroh completion loop for a partner that streams while waiting for you
  to drain output.
- **`driver.PollHost` accepts only its integrated pollable transports.** TCP
  fits directly. iroh and WebRTC use their completion loops (the WebRTC
  backend adopts signaled peers and dials through a configured signaling
  authority); `inproc` and the WebRTC blocking tier use
  `driver.BlockingSession`.
- **Callers can still choose an infinite wait.** Zig requires an explicit
  handshake and settle budget, but `.unbounded` remains available. The CLI and
  examples use finite deadlines; library callers must make the same choice.
- **A durable sturdyref survives a restart only if you keep its entropy.** The
  library holds no registry across processes, because the core is sync and
  no-I/O and cannot own a file. What it guarantees instead is that a durable
  name is a pure function of the 16 entropy bytes you passed to
  `publishDurable`: keep those, republish with them at startup, and callers
  holding the old sturdyref reach the new actor. Lose them and the name is
  gone. `Host.Options.bootstrap_durability` still refuses
  `.durable_bootstrap`, which would promise a registry the library does not
  have.
- **Some binding pumps copy outbound frames.** TypeScript, Python, and Racket
  copy bytes before an asynchronous write because their FFI lifetimes cannot
  retain the Zig-owned frame. Rust retains the frame across the write.
- **macOS is compiled but not run in CI, and Windows is not implemented.**
  Linux is the only platform on which the full check set runs today.

## API gaps

- **A sturdyref enliven verifies the complete locator before wire traffic.**
  Every tier's select-or-dial enliven (`driver.PollHost.enliven`,
  `pancake_host_enliven`, and each binding's host-level verb) checks the
  sturdyref's peer against the session it selects or dials. An accepted
  plain-TCP session is refused by default; only the native low-level
  `assertion_only` opt-in proceeds, and it reports that provenance.
- **The opt-in GC finalizer tracks the `fetch` seam only
  ([ADR-0063](decisions/adr/ADR-0063-finalizer-driven-distributed-gc.md)).**
  Each excluded class has its own owner rather than a missing one. A near
  reference has no wire row; its lifetime is the actor-roots policy, with the
  deterministic release verb beside it. A dropped reply promise needs no
  finalizer because answer positions are single-reference and the stateless
  policy releases them. An enlivened capability is owned by the enliven dedup
  cache, which a finalizer would invalidate. The bootstrap position is
  refused in a `gc-exports` by send validation. One deferral is genuine and
  the decision records it: the other lift seams (a capability arriving in a
  send reply or a delivered argument, including a redeemed handoff's) are not
  finalizer-tracked. Those references are released at session teardown, and
  every binding has the deterministic `release` verb for reclaiming one by
  hand before that.
- **The public API and ABI are not stable.** There are no release tags or
  compatibility guarantees yet. Pin a commit when consuming the package.

Archive discovery and packaging are documented in the
[packaging guide](../bindings/PACKAGING.md#finding-the-archives). Windows release
assets are not published.

## Protocol and interop

- **A cleartext keyed-TCP hello can be replayed.** Every connection signs with
  its own key. Each key-designator transport states what authenticates the
  durable identity a hello claims. iroh's QUIC handshake and WebRTC's DTLS
  binding prove it at the transport. keyed-TCP and keyed-relay instead carry a
  `session-key-attestation` signed by the durable key the designator names. A
  partner identity reports which of those proved the name, so an application
  asks provenance rather than comparing a designator against a session key.
  What none of that provides is channel freshness. The attestation and the
  hello signature both cover static records, so a captured keyed-TCP hello
  replayed on another cleartext connection revives its own claim. Fresh keys
  isolate honest reconnects; they do not make cleartext replay-safe. A
  challenge or channel-binding protocol would be a separate wire decision
  ([ADR-0075](decisions/adr/ADR-0075-keyed-tcp-designator.md),
  [ADR-0097](decisions/adr/ADR-0097-captp-session-identity-attestation.md)).
- **OCapN Null is absent.** Unknown Syrup records remain tagged values instead.
  The encoding is an open upstream question
  ([watch](upstream-watch.md#ocapn-null)).
- **Only the negotiated features are accepted.** pancake supports
  `pipelining`, `handoff`, `wire_delta`, and `sturdyref`. Feature names from
  older CapTP designs (streams, equality queries, a `draining` lifecycle)
  exist in neither the pinned draft nor Goblins, so their absence here is not
  an interop gap.
- **Foreign promises have a narrower path than foreign objects.** Passing a
  promise from one session as a `send` or `tell` argument on another is
  refused. A relayed settlement can carry a plain value, a break, a sturdyref,
  or a capability introduced by handoff. A promise, a locally exported object,
  or a capability nested inside a container settles broken instead.
- **Handoff is return-based.** A capability from another session can be
  returned as an answer, but it cannot be pushed as an argument. An application
  that needs to push one must pass a promise for the eventual answer instead.
- **Handoff signatures always use Syrup.** That signing domain does not change
  when the surrounding session uses Cap'n Proto.
- **Remote equality holds per exporter session, not across parallel
  sessions.** A target reached directly and through handoff on the same live
  exporter session lifts to one Host identity and compares Equal. Two
  independently established sessions to the same peer carry no stable target
  id from which pancake could infer equality. A key-designator transport now
  recognises the peer itself, so a second session to one is collapsed rather
  than established; where two do coexist, their targets stay unrelated.
- **Projection responder coverage is partly in-tree.** Field, index, and tag
  projections are implemented. The upstream suite does not cover them, and
  Goblins cannot yet marshal `op:untag`, so not every direction has a live
  outside-peer check.
- **One-way send uses `op:deliver` without an answer.** The draft folded
  one-way delivery into `op:deliver` with a false answer and resolver, and
  that is the frame pancake sends; no separate `op:deliver-only` operation
  exists in the pinned draft, the upstream suite, or Goblins. No live Goblins
  check sends a `tell` today.
- **Two position ranges are reserved internally.** A peer-supplied import at or
  above 2^60, or answer position at or above 2^63, is refused so it cannot
  collide with pancake's internal handoff and virtual-answer ranges. Proven
  peers count upward from zero, so this fails closed before affecting them.

Cap'n Proto is a pancake-to-pancake format. The project does not publish a
fixed speed ratio between the codecs; `zig build bench-codec` measures the
current workload.

[Community review](community-review.md) is the precise outside-peer coverage
and specification-gap record.

## Browser reachability

A browser is a full peer after it has a channel, but it cannot open a listening
socket. Cold dial works through a shared relay. The relay holds an inbound
socket under the browser's keyed identity, and a dialer configured for that
relay (another browser, or a native peer) bridges onto it. The CapTP handshake
still authenticates the peers end to end.

The core classifies a `keyed-relay` locator as the `rendezvous` dial shape for
every consumer. Each consumer opens it through its host's configured relay
mapping: the four language bindings through their runtimes' WebSocket clients,
and native Zig through the in-tree `net.keyed_relay` resident (the CLI joins
it with `PANCAKE_RENDEZVOUS`). The
`zig build bindings-keyed-relay-rendezvous` proof family holds all five rows.
The native resident also serves the registration half, so a native peer that
declines a listener can register at a relay and be cold-dialed; the CLI does
not surface that half.

One reachability path is not built: a cold dial across different relays,
because the locator names the peer identity rather than a relay route.

The [roadmap](roadmap.md) owns those tasks and the unbuilt product work,
including the griddle simulator, protocol visualization, and A2A facade.
