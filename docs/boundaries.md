# Known limitations

These are the limits that can change a deployment or API choice. [What ships](shipped.md)
is the feature inventory. [Stability](stability.md) says how each surface is
tested. The [roadmap](roadmap.md) owns future work.

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
  includes the relay operator even when the carrier leg itself uses WSS.
  Prefer `noise-tcp` or `noise-relay` for pancake-to-pancake sealed channels,
  iroh when discovery or NAT traversal is needed, and WebRTC for a direct
  browser channel.
- **A TCP locator names a socket.** On plain TCP, the crossed-connection
  tiebreak trusts the location each peer declares. A peer that can connect and
  claim an address you are dialing can make your outgoing session lose that
  tiebreak. Only a channel-authenticated key designator can collapse a session,
  so an unproved claim from raw keyed TCP or keyed relay cannot condemn one.
- **Two sessions to one peer stay open on an address transport.** `127.0.0.1`
  and `[::1]` are different designators, and neither is an identity pancake
  will act on, so nothing joins the two sessions. A key-designator transport
  with channel proof recognizes the peer by its durable name and keeps one.
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
- **An onion session upgrades past the `1.0` profile only when the partner is
  known to be pancake.** The pinned Goblins accepts a hinted hello on any
  transport, and `zig build goblins-onion` probes that live. Its dial arm
  still refuses a hinted onion locator, and gift withdrawal is keyed by the
  full node value, so every onion locator on the wire stays bare. A pancake
  peer states a preferred profile over onion only when it already knows the
  other side: it was handed the pancake-hinted form of the address, or it is
  answering a hello that stated a preference. A host on the default baseline
  profile, and every Goblins session, settles the baseline. Two pancake peers
  that both know each other settle `pancake-next` over Tor.
  [ADR-0108](decisions/adr/ADR-0108-onion-netlayer.md) records the locator
  rule.
  [ADR-0118](decisions/adr/ADR-0118-onion-profile-by-knowledge.md) records
  when that offer is allowed. `conformance/ocapn-findings` is the Goblins
  behavior record.
- **iroh reachability is not fully exercised in CI.** The loop checks
  multiplexing, and opt-in checks cover discovery and relay use from one host.
  They do not cover hole-punching between separate NATs.
  `discovery_no_relay` has no green check because it needs a publishable direct
  address. A live Goblins-over-iroh session does have one, `goblins-iroh`, over
  the iroh netlayer this repository wrote for Goblins; it runs on loopback with
  direct dial (no relay), so it adds no reachability evidence.
- **A `webrtc` dial needs configured signaling authority.** On TypeScript, a
  runtime composed with `webrtc.connector(signaling)` dials a bare `webrtc`
  locator: the connector runs the offer, answer, and candidate exchange and
  holds the keyed session over the opened DataChannel. Native Zig sets that
  authority on the WebRTC backend rather than on Session. Without it the dial
  refuses.

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
  completion. Outside this provider seam, a native Zig netlayer declares one
  tagged dial execution form, blocking or staged.
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
  realizes `noise-tcp`, `keyed-tcp`, and testing `tcp`. Key-addressed profiles take
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
- **macOS runs the native suite, and Windows is not implemented.** The full
  gate and external-runtime matrix remain Linux-only.

## API gaps

- **The IRC adapters have IRC representation and delivery limits.** The bridge mirrors one channel into an
  ordinary Rooms directory and is read-only unless the operator selects
  two-way mode with TLS and SASL credentials. Two-way posts use the bridge's
  registered nick and a visible `<nick>` prefix. IRC supplies no acknowledgement
  for a channel message, so an ambiguous TCP failure may repeat or lose the last
  line even though the bounded queue survives an observed write failure. The
  client front maps only existing IRC-addressable room names. It fixes a
  nickname for the connection because Rooms grants names per capability and no
  atomic rename exists across several memberships. Native names outside IRC's
  alphabet receive disclosed connection-local aliases. Lines, topics, and file
  capabilities that cannot fit IRC are reported rather than silently truncated
  or discarded. Foreign room publications without a member count, and native
  room names IRC cannot address, are omitted from `LIST` with a notice instead
  of invented fields. IRC carries neither edits nor capability-bearing file and
  room offers. IRC is an application adapter, never a CapTP transport; there is
  no IRC server link and no CapTP-over-IRC netlayer.

- **A sturdyref enliven verifies the complete locator before wire traffic.**
  Every tier's select-or-dial enliven (`driver.HostRuntime.enliven`,
  `pancake_host_enliven`, and each binding's host-level verb) checks the
  sturdyref's peer against the session it selects or dials. An accepted
  plain-TCP session is refused by default; only the native low-level
  `assertion_only` opt-in proceeds, and it reports that provenance. Dial
  staging is a Node prepare/commit transaction: Host parking and completion
  capacity are acquired before a dial action becomes observable.
- **The public API and ABI are not stable.** There are no release tags or
  compatibility guarantees yet. Pin a commit when consuming the package.

Archive discovery and packaging are documented in the
[packaging guide](../bindings/PACKAGING.md#finding-the-archives). Windows release
assets are not published.

## Protocol and interop

- **Locator hint count is an implementation resource bound, not an OCapN wire
  maximum.** pancake accepts at most 32 entries in one locator hint map across
  owned values, Syrup, Cap'n Proto, and URI parsing. URI parsing refuses the
  33rd entry before decoding or allocating it. Unknown names within the bound
  remain preserved and ignored unless a negotiated feature owns their meaning.

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
  `pipelining`, `handoff`, `wire_delta`, `sturdyref`, `untag`, and the
  ADR-0125 `multi_location` bit. Identity-route vocabulary is opt-in: an `id`
  locator is refused before send or apply unless the settled session is
  `pancake-next` with that bit. Host-level `id` sturdyrefs also require the
  Host to opt into that same feature and then match only authenticated same-key
  sessions or staged concrete `via` routes. Feature names from older CapTP
  designs (streams, equality queries, a `draining` lifecycle) exist in neither
  the pinned draft nor Goblins, so their absence here is not an interop gap.
- **Route bundles select only at their owner.** ADR-0125 route bundles drive
  Node handoff/redeem scheduling for `alt-locators` and `id` `via`, and
  signed-give lowering for `id`. A give preserves route vocabulary only when both its
  recipient and exporter sessions negotiated it; a baseline-compatible
  override remains usable, while private vocabulary falls back to the concrete
  location the exporter claimed on its session. The generic single-path dial planner and Host open
  path still refuse bundle transports as physical sessions; only the Node
  pending-dial waist resolves `id` into a concrete transport. Declared `via`
  order ranks a two-attempt window, the first proved completion wins, and exact
  losing route attempts are cancelled before their executor state retires. A
  weak fallback serves only its authorizing ticket; it is cached as the
  canonical exporter session only when the channel independently proves the bundle's durable
  identity. Discovered route advice becomes available to later gives only
  after one withdrawal succeeds. Rooms composes active listeners into an
  identity route and uses the existing handoff path to publish durable rooms
  between directories; ordinary member introductions still relay the
  member's signed session location.
- **Handoff signatures always use Syrup.** That signing domain does not change
  when the surrounding session uses Cap'n Proto.
- **Pinned Goblins can reject handoffs from independent receivers.** Goblins
  records an accepted `handoff-count` on the Gifter-Exporter session, although
  the certificate assigns that count to the Receiver-Exporter session. Two
  independent receivers can therefore each correctly begin at zero while the
  second is rejected against the first receiver's retained count. Pancake keeps
  one V1 issuance cursor for replacement sessions inside a Node, which handles
  reconnects but cannot coordinate independent recipients. The live
  `goblins-rooms-matrix-iroh` step reproduces the rejection; the source-level
  mismatch is tracked in
  [upstream watch](upstream-watch.md#handoff-count-across-independent-receiver-sessions).
- **Remote equality does not cross unrelated sessions.** A proved exporter
  session gives direct and handed-off references one Host identity. Two
  independently established sessions without durable peer proof carry no
  stable target id from which pancake could infer that identity, so their
  targets remain unrelated even when their locators look alike.

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
and the native CLI honor locator-carried routes over a local fallback that is
not running. `zig build zig-keyed-relay-register` proves the CLI registration
half. The relay provider archive owns both `keyed-relay` and `noise-relay`,
including native dial and registration through the generic driver. The
managed browser connector carries both profiles, while the byte-fed Host owns
Noise sealing. `zig build bindings-noise-relay-listen` has every native
event-loop binding register, advertise, accept, and serve through its managed
listener. `zig build web-peer-test` drives the browser path in Chromium and
has the native CLI call an object hosted in the page over `noise-relay`.

`zig build bindings-native-wss-relay` additionally runs every native binding
against one local WSS authority. Each binding observes exact hostname and
unknown-authority refusals from the shared C provider, then completes a call
and joins the session close barrier. The binding rows prove projection and
foreign linkage; the Zig TLS scenarios remain the semantic authority.

That proof uses a loopback `wss://` relay and a fixture authority copied into
the native process. The optional native Zig relay module and the C relay
archive compose a pollable WSS carrier with immutable
system or copied-PEM trust, SNI, and hostname verification. The completion-loop
relay path drives the same neutral TLS transform below the existing WebSocket
machine without a thread or second framing pass. Its deterministic engine gate
proves transition, refusal, cleanup, and footprint behavior. `zig build
native-tls-build` uses real local certificate chains for both carriers. It
proves success, unknown and expired authorities, hostname and SNI refusal,
peer alerts, malformed TLS, and authenticated truncation without
`close_notify`. It also proves completion delivery of the terminal TLS close
record and a hostname open through its asynchronous resolver and bounded
eight-seat address race. No public-certificate relay check yet proves a native
peer reaching a browser through a deployed secure route; the recurring proof
uses a local authority so expiry, hostname, and plaintext observation stay
deterministic.

Rooms gives browser WebRTC peers public STUN by default, so ordinary NATs can
produce server-reflexive candidates. A deployment can configure an HTTPS TURN
credential issuer for symmetric NATs and restrictive firewalls: the Rooms
server retains the issuer bearer token and publishes bounded, short-lived
credentials to each new browser connection. With no issuer configured, the
posture remains STUN-only and those networks can still leave no candidate pair.
TURN is a relay under the end-to-end DTLS channel, not an automatic switch to
the browser's separately selectable **Through the room relay** transport.
Native WebRTC embeddings pass the same provider-neutral ICE facts as fixed C
records: URLs plus optional username/password credentials. They still own any
credential API, expiry, and refresh policy above the transport.

Native `rooms-peer` composes iroh and the sealed relay backend, not WebRTC, so
it cannot signal a default browser tab. It answers on an inbound WebRTC reply
capability, or cold-dials a tab that selected `noise-relay`. A tab that wants
native-initiated DMs picks **Through the room relay** in Settings or opens with
`?dm=relay`.

A room stores posted files under its room and server ceilings. A direct-message
file has no server in its path, so its sender hosts the blob on the direct
session until the recipient has pulled it. The TypeScript sender retains at
most 128 unfetched sources and 64 MiB, then expires the oldest. If the session
ends or the ceiling expires a file first, the recipient keeps the message
metadata but cannot fetch bytes it never received.

The [roadmap](roadmap.md) owns those tasks and the remaining product work,
including the A2A facade, OpenTelemetry export, the object layer, and control
capabilities.
