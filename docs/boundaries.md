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
  onion (and an in-process `fake`), not TCP. The OCapN suite's equivalent is
  named `tcp-testing-only` and declares itself unsafe in its own source. The
  Goblins TCP netlayer these checks dial is a shim in this repository. Use
  `tcp` to reach a peer that speaks nothing else, not to deploy.
- **`keyed-tcp` and `keyed-relay` are cleartext and unauthenticated.** Their key
  designator is a stable dial target, but the channel proves no possession of
  it. Anyone on the path reads and can alter every frame; on `keyed-relay` that
  includes the relay operator, whose leg the native resident opens as `ws://`.
  Prefer `noise-tcp` or `noise-relay` for pancake-to-pancake sealed channels,
  iroh when discovery or NAT traversal is needed, and WebRTC for a direct
  browser channel.
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
- **`onion` is proven live against the portable upstream suite, but not at scale.** `zig build
  onion-interop` holds a session between two pancake peers and restores the same
  service in a fresh process. `zig build goblins-onion` does it with a real
  Spritely Goblins vat in both directions. `zig build ocapn-conformance-onion`
  passes the complete portable upstream suite plus the strict abort probe through the
  upstream onion netlayer. The local fake-daemon checks cover the blocking
  resident, generic provider package, native Zig `OnionLoop`, and provider
  installation from every native binding. Live steps need `tor`
  and outbound network access, so they remain siblings of `check`. No recorded
  live-Tor scale run exists.
- **An onion session runs the `1.0` profile.** The hints that would state a
  wire-profile preference cannot ride an onion locator, so two pancake peers over
  Tor settle the baseline rather than `pancake-next` (ADR-0108).
- **iroh reachability is not fully exercised in CI.** The loop checks
  multiplexing, and opt-in checks cover discovery and relay use from one host.
  They do not cover hole-punching between separate NATs.
  `discovery_no_relay` has no green check because it needs a publishable direct
  address. A live Goblins-over-iroh session does have one, `goblins-iroh`, over
  the iroh netlayer this repository wrote for Goblins; it runs on loopback with
  direct dial (no relay), so it adds no reachability evidence.
- **A `webrtc` dial needs configured signaling authority.** On the TypeScript
  stack, a host configured with `Host.setSignaling` dials a bare `webrtc`
  locator: the dial executor runs the offer, answer, and candidate exchange
  and holds the keyed session over the opened DataChannel. Without that
  authority the dial refuses. Native Zig does the same: the completion backend
  dials through a configured `SignalingAuthority` and adopts signaled peers
  into the generic Host.

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

- **TypeScript on Bun cannot host the native driver loop.** Bun's FFI executes
  native calls on its JavaScript thread, so a listener or blocking transport
  lifecycle could park the reactor. Those APIs refuse before allocating a
  native runtime. The synchronous Host and locator surface and byte-fed client
  path remain available; Deno owns the full native-loop binding proof.

- **A Host's actor runtime (its Vat) is single-threaded and non-preemptive.** A
  hosted behavior runs synchronously to the end of its turn. A slow or blocking
  handler therefore stalls every session adapter (Port) sharing that Host. Keep
  handlers bounded. Separate Hosts provide scheduling isolation by also
  separating network identity and actor graphs; when those must remain shared,
  move blocking work out of the behavior callback. The actor layer's mechanism
  for that is the resolver vow
  ([ADR-0102](decisions/adr/ADR-0102-off-turn-settlement.md)): a behavior
  defers its answer atomically and the work's completion settles
  it later through `Vat.fulfillVow` or `Vat.breakVow`, on the owning thread.
  A byte-fed embedder has the same seam over the C surface
  (`pancake_host_turn_defer` and its settle verbs). A TypeScript or
  Python behavior that returns a promise defers this way automatically, and
  the Rust and Racket bindings expose the resolver pair directly. A native
  worker thread hands its settle back through `driver.SettleMailbox`: the
  post wakes the owning thread's wait — `driver.HostRuntime` polls the mailbox's fd
  beside its wires, and the completion loop arms a recv on it — and the
  settle applies there. Off-thread settles carry plain data only; a
  capability never crosses threads.
- **The 500,000-session target has not been proved under live socket load.**
  Checked budgets hold the warmed protocol core near 2 KiB per session, and the
  loop checks serve many connections, but neither is a 500,000-connection run.
  [The 1.0 ladder](ladder.md) carries the measured budgets.
- **The simplest blocking pump serves one connection on one fiber.** Use a
  completion loop (TCP, iroh, onion, or keyed-relay outbound) for a partner that
  streams while waiting for you to drain output.
- **`driver.HostRuntime` hosts descriptor-backed transports and multiplexed
  providers.** A stream transport needs a pollable socket:
  TCP, keyed TCP, onion, and keyed-relay fit directly, while `inproc` reports
  no readiness and stays on `driver.BlockingSession`. A transport that
  multiplexes connections behind one shared readiness descriptor joins
  through the common provider package ABI (ADR-0112), which covers dials,
  listener metadata and lifecycle, accepted-connection claim, and teardown.
  iroh implements the multiplexed execution entry in that provider package
  (`pancake_iroh_transport_provider`, with both dial and accept proven live by
  `zig build iroh-driver-provider`). WebRTC implements the package's external
  connection claim: its archive owns signaling and opens the DataChannel, then
  `pancake_driver_adopt_external` transfers either session role to the generic
  driver. `zig build webrtc-driver-provider` proves both halves and an
  authenticated capability fetch.
- **`libpancake_driver` steps one `HostRuntime` from C.** It parks behind one
  readiness descriptor (epoll on Linux, kqueue on Darwin; elsewhere
  `pancake_driver_readiness_fd` fails typed while the stepping verbs keep
  working). Dial and accept handshakes advance across steps under the
  handshake budget, so two loops on one thread can dial each other and a
  stalled connector cannot park the step. Stream providers begin connects
  through a nonblocking `start_connect` contract and publish readiness-driven
  completion; native Zig netlayers without `start_dial` retain the blocking
  fallback outside this provider seam.
- **Pre-open memory is explicitly bounded.** `max_pending_opens` defaults to
  256 per driver Host and counts transport connects plus CapTP handshakes
  across dial, accept, external adoption, and redeem. Over-limit stream
  accepts remain in the kernel backlog; multiplexed-provider accepts are claimed
  and closed without minting a session. Applications can tune the bound with
  the wire-buffer and deadline policy they deploy.
- **A driver loop permits at most one listener per registered provider
  profile.** Listener ids route accepts independently; listeners can be
  selected as the Host's acceptable route and closed individually. A provider
  package may impose a narrower runtime limit. Closing the selected listener
  leaves no acceptable route until the caller selects another.
- **Provider packages own which profiles the loop can open.** The TCP package
  realizes `tcp`, `keyed-tcp`, and `noise-tcp`. Key-addressed profiles take
  their designator from the wrapped Host and expose the bound address as a
  separate listener hint; `noise-tcp` seals and authenticates the channel in
  the Host. Other transports arrive as packages. Iroh's multiplexed provider
  (`pancake_iroh_transport_provider`) owns listener start, metadata, accept
  claim, stop, and dial. Providers that cannot host refuse listener start
  explicitly.

  The relay package can dial both `keyed-relay` and `noise-relay`, but may host
  only one at a time. The deployed rendezvous protocol queues inbound legs by
  durable designator without a channel-profile discriminator. Two relay
  listeners would therefore route nondeterministically.
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
  Every tier's select-or-dial enliven (`driver.HostRuntime.enliven`,
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

- **Keyed TCP and keyed relay prove no peer.** Matching the hello's key claim
  rejects an accidental mismatch, but the cleartext channel reports
  `unauthenticated`. A fresh session key limits honest reconnects; it does not
  stop a captured hello from being replayed. iroh, WebRTC signaling, and
  `noise-tcp` / `noise-relay` supply connection-scoped identity proof
  (ADR-0107). `BlockingSession` refuses Noise symbols.
  An embedder with its own authenticated channel records the same fact through
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
socket. Cold dial works through a relay that holds an inbound socket under the
browser's keyed identity. A `rendezvous-relay` locator hint carries the route,
so the dialer need not share the registrant's deployment configuration. Raw
`keyed-relay` reaches the peer but proves nothing and leaves frames cleartext.
WebRTC supplies encryption and signaling authority. `noise-relay` seals the
CapTP stream end to end (ADR-0107).

`zig build bindings-keyed-relay-rendezvous` proves Deno, Python, Rust, Racket,
and the native CLI honor locator-carried routes over a deliberately dead local
fallback. `zig build zig-keyed-relay-register` proves the CLI registration
half. The relay provider archive owns both `keyed-relay` and `noise-relay`,
including native dial and registration through the generic driver. A real
Chromium wasm peer reports `authenticated_transport` on a live `noise-relay`
session under `zig build rooms-web-noise-relay-provenance`.

The [roadmap](roadmap.md) owns those tasks and the remaining product work,
including the A2A facade, OpenTelemetry export, the object layer, and control
capabilities.
