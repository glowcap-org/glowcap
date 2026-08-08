# Known limitations

These are the limits that can change a deployment or API choice. This page is
not a backlog or a design history. [What ships](shipped.md) is the feature
inventory, [stability](stability.md) says how each surface is tested, and the
[roadmap](roadmap.md) owns future work.

## Transports and peer identity

- **Plain `tcp` is a testing transport.** Its designator is an address, so the
  peer claims no identity and proves none, and the channel is cleartext. That
  fails the OCapN draft's own netlayer requirement that a session be secure
  enough that only its participants can insert messages. Upstream Goblins ships
  no TCP netlayer, and the OCapN suite's equivalent is named `tcp-testing-only`
  and declares itself unsafe in its own source. The Goblins TCP netlayer these
  checks dial is a shim written in this repository for interoperability work.
  Use `tcp` to reach a peer that speaks nothing else, not to deploy.
- **`keyed-tcp` and `keyed-relay` are cleartext and unauthenticated.** Their key
  designator is a stable dial target, but the channel proves no possession of
  it. Anyone on the path reads and can alter every frame; on `keyed-relay` that
  includes the relay operator, whose leg the native resident opens as `ws://`.
  Use iroh or WebRTC for production channel identity and confidentiality.
- **An address is not an identity.** On plain TCP, the crossed-connection
  tiebreak trusts the location each peer declares. A peer that can connect and
  claim an address you are dialing can make your outgoing session lose that
  tiebreak. Only a channel-authenticated key designator can collapse a session,
  so an unproved claim from raw keyed TCP or keyed relay cannot condemn one.
- **Two sessions to one peer stay open on an address transport.** `127.0.0.1`
  and `[::1]` are different designators, and neither is an identity pancake
  will act on, so nothing joins the two sessions. A key-designator transport
  with channel proof recognises the peer by its durable name and keeps one.
- **`inproc` is a test transport.** Its unbounded pipes block the reading
  thread, so it is not a production or load-test substitute.
- **iroh reachability is not fully exercised in CI.** The loop checks
  multiplexing, and opt-in checks cover discovery and relay use from one host.
  They do not cover hole-punching between separate NATs.
  `discovery_no_relay` has no green check because it needs a publishable direct
  address. A live Goblins-over-iroh session does have one, `goblins-iroh`, over
  the iroh netlayer this repository wrote for Goblins; it runs on loopback under
  the direct posture, so it adds no reachability evidence.
- **A `webrtc` dial needs configured signaling authority.** On the TypeScript
  stack, a host configured with `Host.setSignaling` dials a bare `webrtc`
  locator: the dial executor runs the offer, answer, and candidate exchange
  and holds the keyed session over the opened DataChannel. Without that
  authority the dial refuses. On the native side the same posture holds: the
  completion backend dials through a configured `SignalingAuthority` and
  adopts signaled peers into the generic Host.

The iroh and WebRTC transports rely on their existing sidecars; pancake does
not ship a native Zig QUIC or WebRTC stack.

- **A peer that dies without closing is noticed on iroh in seconds, not at
  once.** A TCP peer killed at the terminal is reported gone immediately: the
  OS sends a FIN and the far end reads end of stream. UDP has no equivalent, so
  a killed QUIC peer simply stops answering.
- **iroh ends a silent peer with an idle timeout.** The sidecar turns that into
  a closed event (`transports/iroh/src/lib.rs`). The default is fifteen seconds;
  set `PancakeIrohConfig.idle_timeout_ms` (surfaced on every binding) when a
  live session means presence. Rooms asks for eight. There is no separate
  keep-alive: the transport derives the heartbeat from the timeout. A shorter
  timeout costs more idle traffic, charged against the per-connection budget in
  [`docs/ladder.md`](ladder.md).

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
- **Third-party codec registration is Zig-native today.** The C ABI and the
  language bindings can select the built-in Syrup and Cap'n Proto codecs, but
  they cannot install a new codec implementation into the registry. A future
  binding-facing codec extension should be an extension archive or Wasm
  component registered at the codec seam, with explicit frame ownership and no
  per-frame callback into a host-language runtime.
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
  Other classes already have owners:
  - near references: actor-roots policy, plus the deterministic release verb;
  - dropped reply promises: single-reference answers, released by the
    stateless policy;
  - enlivened capabilities: the enliven dedup cache;
  - bootstrap: refused in a `gc-exports` by send validation.
  One real deferral remains: capabilities lifted from a send reply or a
  delivered argument (including a redeemed handoff) are not finalizer-tracked.
  They release at session teardown, and every binding has `release` for reclaiming
  one by hand before that.
- **The public API and ABI are not stable.** There are no release tags or
  compatibility guarantees yet. Pin a commit when consuming the package.

Archive discovery and packaging are documented in the
[packaging guide](../bindings/PACKAGING.md#finding-the-archives). Windows release
assets are not published.

## Protocol and interop

- **Raw keyed TCP and keyed relay do not authenticate a peer.** Their key
  designator is a stable dial target and a claim in the hello. Matching it
  rejects an accidental mismatch, but the cleartext channel proves no key
  possession and reports `unauthenticated`. A fresh session key limits honest
  reconnects to distinct CapTP identities; it does not stop a captured hello
  from being replayed. iroh, WebRTC signaling, and the planned Noise channel
  supply connection-scoped identity proof. An embedder that realizes its own
  authenticated channel records the same fact through
  `pancake_host_session_bind_verified_channel_key`.
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
- **Goblins indexes exporter sessions by the complete locator.** A give must
  therefore carry the same locator snapshot the exporter advertises in its
  hello. pancake keeps that snapshot on the peer instead of reconstructing it
  at the handoff site. Onion locators remain the stable
  `(onion, service-id, #f)` value Goblins expects. An iroh deployment without
  reachability may refresh `direct-addresses`; the new snapshot applies to
  subsequent sessions and gifts. This upstream lookup behavior is pinned
  interop evidence, not a pancake architecture boundary.
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
  Goblins has no `op:untag`; default `1.0` refuses it, so only `pancake-next`
  has tag projection. `zig build goblins-interop` proves a live Goblins
  netlayer can write canonical `op:get` and `op:index` frames, and that
  pancake settles the projected answers through the V1.0 resolver-callback
  form Goblins uses. That Racket path still bypasses a public Goblins
  application-level projection API, so the remaining live gap is `op:untag`.
- **One-way send uses `op:deliver` without an answer.** The draft folded
  one-way delivery into `op:deliver` with a false answer and resolver, and
  that is the frame pancake sends; no separate `op:deliver-only` operation
  exists in the pinned draft, the upstream suite, or Goblins. A live Goblins
  vat accepts that frame: `zig build goblins-interop` sends two one-way
  delivers to a stateful actor and then reads the count back through an
  answered call, which is the only way an unanswered send can prove it
  arrived.
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
relay (another browser, or a native peer) bridges onto it. The relay carries
bytes and proves nothing. Raw `keyed-relay` therefore provides reachability but
not peer authentication or confidentiality. WebRTC supplies both through its
DTLS channel and signaling authority; ADR-0107 proposes Noise_XK for an
end-to-end sealed byte channel through the relay.

The core classifies a `keyed-relay` locator as the `rendezvous` dial shape for
every consumer. Each consumer opens it through its host's configured relay
mapping: the four language bindings through their runtimes' WebSocket clients,
and native Zig through the in-tree `net.keyed_relay` resident (the CLI joins
it with `PANCAKE_RENDEZVOUS`). The
`zig build bindings-keyed-relay-rendezvous` proof family holds all five rows.
The registration half is native too: `pancake ocapn listen --rendezvous
ws://host:port/register` binds no listening socket, holds an inbound socket at
the relay under its key designator, and prints the `keyed-relay` locator that
names it. `zig build zig-keyed-relay-register` proves a CLI registrant
answering a CLI cold dial.

One reachability path is not built: a cold dial across different relays,
because the locator names the peer identity rather than a relay route.

The [roadmap](roadmap.md) owns those tasks and the remaining product work,
including the A2A facade. The griddle simulator and protocol visualization ship
today; what they still lack is named in the roadmap's Beyond the library
section.
