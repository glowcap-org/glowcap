# What ships today

glowcap is unreleased, but the library, bindings, transports, and tools below are implemented and checked in this
repository. Outside interoperability is signed CapTP 1.0 over Syrup. Recurring
[Spritely Goblins](https://spritely.institute/goblins/) evidence uses the cleartext `tcp` testing adapter. Read
[known limitations](boundaries.md) before deploying it and [stability](stability.md) for the evidence behind each
support claim. If capabilities are new, [capabilities](capabilities.md) starts from zero.

## Application APIs

| Surface      | What it provides                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Zig          | `driver.Session` connects or listens, fetches and publishes capabilities, calls them, and redeems three-party introductions. `driver.HostRuntime` owns the sessions behind that API.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| I/O-free Zig | `engine.Peer` exposes the protocol engine without sockets or scheduling. Callers feed frames, step the engine, drain output, and handle events.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| C            | Opaque handles, fixed-width result codes, explicit release, and a close that takes a pending-work policy (`GlowcapCloseOptions`). Managed frames carry ownership inline without a descriptor allocation or byte copy. Separate archives cover the core, Host, native loop, and transports; every archive exposes a fingerprint derived from reflected functions, public constants, and canonical layout manifests. Binding-projected manifest rows also generate language mirrors, while C-only rows remain out of package APIs. Generated binding loaders compare each fingerprint before ordinary use so a stale companion is refused. Structured diagnostic reports validate stable result codes and consequence shape before crossing into retained storage; fallible blocking transport calls can return their worker-thread diagnostic in caller-owned storage. Every status call begins a fresh archive-local diagnostic fact, so an undetailed refusal cannot inherit an earlier call's cause. |
| Bindings     | Rust, TypeScript, Python, and Racket expose the same session and actor model through the C ABI. They can dial, listen, host objects, call far objects, and pass capabilities.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Browser      | `@glowcap/web` runs a full peer in WebAssembly. A browser can host objects, answer calls, redeem handoffs over WebSocket, register for sealed `noise-relay` cold-dials, and hold an ordinary keyed session over WebRTC after signaling.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |

The [Zig examples](../examples/README.md), [C guide](consuming-from-c.md), and [binding contract](../bindings/README.md)
are the entry points for those surfaces.

Binding fronts compose `libglowcap_host` and `libglowcap_driver`. The driver provides one generic dial/listen/event ABI
over an adopted Host. The TCP provider package owns `noise-tcp`, `keyed-tcp`, and testing `tcp`; separately built
transports register through the common ABI. The iroh provider owns both dial and listener operations, and the onion
archive supplies the standardized Tor transport without teaching the driver its symbol. Zig and all four bindings host
onion through the same Session listener lifecycle as the other providers; only the onion package interprets the
listener's opaque restoration bytes as a Tor service key. An idle Host that is not yet pumping can move into this
runtime in one step: success preserves its identity and capabilities, and a refused transfer leaves the original Host
untouched. After a successful transfer, later setup failure preserves that valid adopted Host for retry. Listener close
preserves sessions already yielded. Wasm and explicitly supplied byte channels use the byte-fed Host instead.

## Protocol

- **Sessions.** glowcap negotiates a signed CapTP session and owns its imports, exports, answers, and releases. It
  validates messages before applying them and sends a typed abort when a protocol error requires the session to close.
- **Calls and promises.** Applications can fetch a bootstrap capability, call it, send without waiting, and pipeline
  calls or field, index, and tag projections through an unresolved answer. Glowcap accepts the OCapN 1.0 `op:untag`
  operation unconditionally; it sends one only when the partner's signed hello advertises the independent `untag`
  feature, so a silent Goblins peer remains on the proven compatibility set without redefining the version. V1.0
  resolver-only calls retain a typed local answer through the same reply path without fabricating a wire position; every
  `u64` remains available to a partner as an answer position, and wire GC cannot alias the local row. One-way sends use
  the draft's answerless `op:deliver` form; there is no separate `op:deliver-only` operation in the pinned draft or
  Goblins.
- **Persistent references.** A sturdyref is a durable peer-locator plus swiss name that can be enlivened into a live
  capability. Session-level enlivenment checks the complete peer locator before cache lookup or wire traffic; repeated
  enlivenment on that session shares the same import. A mismatched peer or an accepted plain-TCP assertion is refused.
  Pending enlivenments reserve their combined bounded cache demand before issuing the fetches; fulfillment moves
  their owned swiss names into the cache without allocation, even when direct insertions share that cache.
- **Route bundles.** Handoff fallback and `id` `via` route hints parse through one model-owned route bundle. `id` is the
  one private multi-home shape: its designator names the durable key and its strong routes must prove that key. Handoff
  gives use route vocabulary only when both the recipient and exporter sessions negotiated it. For a baseline exporter,
  a baseline-compatible override remains usable while private route vocabulary falls back to its concrete session
  location. A baseline recipient lowers `id` to the first compatible route, strips private route vocabulary, or fails
  closed when no such route exists. Node redeem admits `id` dials only through routes that can prove the same durable
  key as the outer id. Declared `via` order is the route rank: Node keeps a two-attempt strong-route window full in that
  order, accepts the first proved completion, and cancels exact losing `(ticket, route_index)` attempts. Optional
  `alt-locators` remain serial weak handoff fallbacks after that race is exhausted: they can redeem the signed gift that
  authorized the dial but do not establish the outer identity, enter its durable cache, or become a sturdyref dial path.
  Route advice is retained for later gives only after a withdrawal succeeds. Host-level sturdyref enlivenment supports
  `id` sturdyrefs only when the Host opts into `glowcap-next` with `multi_location`; it selects an already authenticated
  same-key session or stages the concrete routes through the pending-dial waist. Host `fetchAt` exposes the same route
  owner for a named publication from a typed locator; applications choose neither CapTP version nor codec for that
  operation.
- `zig build rooms-chat-build` installs the native interactive client.
  `zig build rooms-chat -- <locator> <room> <nick>` runs it as an interactive
  Rooms client. Its installed-process scenario covers TCP and iroh, live listing
  and traffic, refused-switch preservation, oversized input, EOF and signals.
  The Deno interactive chat entrypoint has been removed.
- `zig build rooms-web-operations-refresh` exercises Rust operations pagination,
  search, capability removal and reload on the production browser page.

- **Rooms.** The Rooms application composes the protocol above into a product.
  Portable Rust owns room and directory policy, persistent authority, workspace
  intent, session recovery, commands and outcome reconciliation, files, archives,
  operations, peering and IRC. Rust runs every server and session-peer process.
  The production browser links that application with glowcap's Zig Host in one
  Wasm module for local, hosted and attached sessions; React supplies reader
  gestures and renders typed observations. A gesture, its admitted intent, and
  its asynchronous outcome remain distinct: generations and operation identities
  prevent a stale completion from clearing newer input, moving the current view,
  or reviving retired authority. Expected failures retain typed codes and recovery
  advice; unexpected worker, adapter and cleanup failures reach a generic retained
  owner. Bounded queues refuse pressure before mutation, ambiguous effects remain
  recoverable, and shutdown joins admitted work. Native services provide the room
  server, durable sessions and archives, HTTP front, relay and readiness,
  visualization, PostgreSQL history, Tor/onion startup, and both IRC edges.
  Browser integration covers reconnect, shared sessions, files, archive retention,
  operations, direct messages, WebRTC, relays, TCP and iroh forwarding, and live
  visualization. [The Rooms page](../apps/rooms/README.md) owns the feature
  inventory, [operating Rooms](../apps/rooms/operating.md) owns recovery and
  deployment bounds, and the historical
  [Rust migration record](planning/rooms-rust.md) names the evidence. No migration
  performance improvement is claimed.

- **Three-party handoff.** A capability received from one peer can be returned or passed recursively to another. Inbound
  signed gives become Host-owned promises immediately. Outbound foreign objects and promises wait as one bounded
  transaction until every gift id, exporter deposit, shared promise listener, recipient escrow, and rewritten message
  can commit. Core and C Host cover terminal failure. Node-local routes use an explicit reference arm, so every `u64`
  remains available to a peer as a wire import and an unlowered route is structurally refused by codecs. The recurring
  Deno, Python, Rust, and Racket gifter matrix proves two nested gives against live Goblins.

- **Relayed promise settlement.** When a shared home promise settles, its complete Passable value crosses Host identity
  once. Each recipient reuses the bounded Passable transaction. Nested objects become gives, and nested promises become
  successor proxies. A recipient that cannot admit its projection breaks without publishing a prefix. No sibling rolls
  back. The live Goblins evidence covers both directions. A Goblins recipient reads glowcap's relayed give. In the
  reciprocal scenario, an owning native Session installs `listenTo` on a Goblins-owned pending promise. Goblins then
  settles it to a list containing a callable capability.

- **Handoff capability ownership.** Deposited gifts keep the exact actor in the Host Vat
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)). Zig and the bindings can also listen for
  settlement of a promise received from a peer. The native path is recurring live Goblins evidence, including recursive
  capability lifting and explicit release ([ADR-0095](decisions/adr/ADR-0095-listening-on-a-received-promise.md)). Gifts
  and replay counters live on the sessions that own them; product Hosts mint a fresh signing key per session
  ([ADR-0100](decisions/adr/ADR-0100-session-owned-handoff-authority.md),
  [ADR-0097](decisions/adr/ADR-0097-captp-session-identity-attestation.md),
  [ADR-0116](decisions/adr/ADR-0116-inline-passable-handoff.md)).
- **Identity.** A session can report the identity its handshake established. On `driver.Session`, the C ABI, Wasm, and
  the bindings, every application capability is one opaque Host-scoped identity
  ([ADR-0096](decisions/adr/ADR-0096-host-scoped-capability-identity.md)). Repeated lifts on one live exporter session —
  including a target reached directly and through three-party handoff — converge on that identity. C compares the opaque
  ids; Rust, Python, and Racket use their native equality operations, and TypeScript uses `Ref.equals` because each
  wrapper occurrence independently owns one native retain. Release state is not part of equality. Wire positions surface
  only on the low-level `engine.Peer` and `BlockingSession` tiers.
- **Publication.** Each session reaches the Host's shared Vat through its own Port. Publishing changes discovery only;
  issued capabilities and deposited gifts keep the exact actor until their roots release
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)). Durable publication is a separate namespace
  ([ADR-0098](decisions/adr/ADR-0098-sturdyref-peer-authority.md)): the Host mints an unpredictable swiss name, never
  reassigns it, and returns the complete sturdyref. Host enlivenment selects a live matching session or dials the
  sturdyref peer itself.
- **Locators.** Zig, C, and the bindings parse and format `ocapn://` peer and sturdyref URIs. Default Host and Session
  enlivenment consume the canonical persistent form; the explicitly named Host variant parses another profile's
  form. Typed Host `fetchAt` takes a locator plus publication name, so application code chooses neither a CapTP
  version nor a sturdyref codec. Applications dial through a locator rather than a transport-specific session API.
- **Resource limits.** Session tables, durable sent-answer resolution bytes, projection depth, nesting depth, and Cap'n
  Proto traversal are bounded. Durable answer retention is independent of transient outbound pressure, so neither ledger
  can deadlock the other. One partner's outbound pressure holds back only the Node actions bound for it. Those park on
  that session and re-enter the queue when its bytes are next taken, while actions for every other session proceed
  ([ADR-0145](decisions/adr/ADR-0145-node-actions-park-per-recipient.md)). The C Host and every binding expose both
  ledgers through one versioned, named session-limit
  options value; zero fields preserve the current Host policy, and already-minted peers keep their snapshot. Distributed
  garbage collection is available as a per-session opt-in in every binding: fetched capabilities, fulfilled far results,
  and recursively nested delivered arguments all return their opaque Host retain through one finalizer seam. A final
  import release also clears sturdyref cache state and makes every old host route fail closed before the partner may
  reuse that position. Binding-local dispatch and ABI projection both refuse a spent capability occurrence, even when
  another occurrence keeps the same Host identity live.
- **Unreturned failures.** The vendor-neutral diagnostics layer and `GlowcapContext` provide one typed, bounded journal
  for a failure whose last deterministic recipient has gone
  ([ADR-0115](decisions/adr/ADR-0115-structured-diagnostic-waist.md)). Recording allocates nothing, saturation preserves
  an explicit sequence gap, and the C claim API leaves a record queued when caller storage is too small. Contexts assign
  every native Host a stable nonzero lifecycle ID, so reports from Hosts sharing a journal remain distinguishable
  without treating reusable addresses as identity. Runtime-surviving binding records use the same aggregate text bound
  and truncation flags. Returned errors, peer aborts, and protocol trace remain separate authorities. Native driver
  events use the same primary/first-consequence/count vocabulary, so an asynchronous dial, listener, or wire-close
  recipient does not flatten its cleanup chain merely because it crosses C. Every native terminal event owns queue
  capacity before its transition commits: opens and listeners reserve at admission, wires at adoption, and completions
  while their Host action is still parked. Provider installation and final driver release return a versioned
  caller-owned record with the exact primary, first consequence, and total consequence count; every binding projects
  that record without parsing thread-local diagnostic text.
- **Close.** Every owning front closes under an explicit pending-work policy
  ([ADR-0114](decisions/adr/ADR-0114-pending-work-close-policy.md)). Cancel stops admitted work at once. Finish seals
  admission and drives already admitted work within a bounded grace. Expiry escalates to cancel. Each owner holds one
  close barrier. The policy ships on the Zig Host, the C ABI (`glowcap_host_close`, `glowcap_host_close_progress`, and
  `glowcap_host_lifecycle_state`), the driver loop, and all four language bindings. Failures stay ordered on the owner
  that can still receive them: the exact primary, a bounded secondary prefix, and the total consequence count. A second
  close joins that barrier instead of running teardown again. Implicit destruction is non-panicking. A fire-and-forget
  local behavior failure cannot become a reply; its Host retains the exception. Callerless and finalizer failures prefer
  the live Context journal; if that recorder is gone they enter the process-scoped queue. Explicit release still raises.
  Provider installation and connector establishment keep the setup error primary and retain cleanup failure beside it.
  Native iroh and WebRTC close failure survives the peer or endpoint handle and returns from the owner's release. Those
  sidecars stay usable from a consumer already inside Tokio: they do not nest `block_on`. Python close raises the first
  object and keeps the rest on `terminal_failures` (at most 64 retained objects, with `terminal_failure_count` for the
  saturated total). Process-scoped leftovers use `take_runtime_failures()`. TypeScript uses `takeRuntimeFailures()` and
  keeps the exact primary object, including frozen application errors. Racket uses `host-take-failures!` and
  `take_failures()` with no separate read/clear journal, and a queue-cap refusal stays `QueueCapExceeded` through
  repeated close. Rust uses the bounded runtime queue. Relay pumps join both legs and return the first I/O failure plus
  ordered close consequences.

The passable-value model and typed C/binding waist cover the pinned OCapN scalar and aggregate forms, including
arbitrary-precision Integer, Struct, and Error-as-fulfilled-data, plus the Set and Keyword forms used by Goblins. Error
data remains distinct from a broken reply at the Host, C, Rust, TypeScript, Python, and Racket surfaces. OCapN Null is
not implemented; see [protocol limitations](boundaries.md#protocol-and-interop).

## Codecs

| Codec       | Use                                                                                                  |
| ----------- | ---------------------------------------------------------------------------------------------------- |
| Syrup       | The interoperable OCapN wire format. Its fixtures are cross-checked against upstream Syrup encoders. |
| Cap'n Proto | glowcap-to-glowcap, with checked golden frames. Goblins speaks Syrup.                                |

The authenticated OCapN 1.0 profile uses Syrup. Two glowcap peers can prefer Cap'n Proto or `"glowcap-next"`. Each side
puts that offer in the hello's locator hints, and `engine.Peer.settleNegotiatedProfile` settles the pair after both
verified hellos arrive. [ADR-0103](decisions/adr/ADR-0103-hello-carried-profile-offers.md) records that handshake. An
absent offer is the v1.0/Syrup floor, so Goblins traffic stays wire-identical. Over onion the offer is sent only when
the partner is known to be glowcap, because the pinned Goblins cannot dial a hinted onion locator. A dial includes the
offer when it was handed the glowcap-hinted address form. An accept includes it when answering a hello that already
stated one. [ADR-0118](decisions/adr/ADR-0118-onion-profile-by-knowledge.md) records that exception. Every binding
exposes `native` and `interop` as coherent Host-profile choices reflected from `model.Preference`; the individual codec
and version selectors remain available for protocol work. Binding checks (`zig build rust-dogfood`, `deno-dogfood`,
`python-dogfood`, and
`racket-dogfood`) exercise the C ABI as a real consumer over a live Cap'n Proto socket. Zig applications can add another
codec through the open registry without changing the protocol core.

## Transports

| Transport     | Use                                                                                                                                                                                                                                                                                                                                               |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `iroh`        | Encrypted QUIC with discovery, relays, and a node ID that also serves as the OCapN designator.                                                                                                                                                                                                                                                    |
| `webrtc`      | An encrypted DataChannel reached through signaling. It carries a normal keyed OCapN session once the channel is open.                                                                                                                                                                                                                             |
| `noise-tcp`   | The keyed-tcp grammar with ADR-0107's sealed channel on the wire: a Noise_XK handshake between the two peers encrypts the channel end to end, and completing it proves the dialed key. The Zig host tiers, C driver loop, and all four native bindings dial and listen on it.                                                                     |
| `noise-relay` | The keyed-relay pipe with ADR-0107's sealed channel: CapTP peers run Noise_XK with each other, and the relay only forwards ciphertext. The native provider and every native binding compose it. Every event-loop binding can register a durable listener or dial this profile; the managed browser connector uses the same byte-fed Host sealing. |
| `onion`       | The standardized OCapN Tor netlayer. A version 3 service id addresses an encrypted, location-hiding circuit; Tor proves the service to the dialer but reveals no caller identity to the listener.                                                                                                                                                 |
| `keyed-tcp`   | TCP with a key designator as the dial target. The channel is cleartext and unauthenticated; the key does not prove possession.                                                                                                                                                                                                                    |
| `keyed-relay` | Cleartext WebSocket to a relay; the key designator is a dial target with no listening address. Trusted network and relay only.                                                                                                                                                                                                                    |
| `tcp`         | Cleartext testing path and this repository's Goblins TCP adapter. A host:port designator.                                                                                                                                                                                                                                                         |
| `inproc`      | An in-process connection for tests and deterministic local scenarios.                                                                                                                                                                                                                                                                             |

`onion` is the draft's transport and the one Goblins ships. Live Goblins also meets glowcap over `tcp` and `iroh`
through adapters in `conformance/goblins-peer/`. In-tree onion checks use fake SOCKS and control daemons under
`zig build check`. Live Tor proofs are `onion-interop`, `goblins-onion`, `ocapn-conformance-onion`, `bindings-onion`,
and `demo-rooms-onion`. See [stability](stability.md) and [known limitations](boundaries.md).

TCP, iroh, and relay join the native loop as transport packages. WebRTC joins that same loop once signaling has opened a
DataChannel. A relay locator can carry its `rendezvous-relay` route, with deployment configuration retained only as the
fallback for a bare locator. A bare `webrtc` locator needs configured signaling authority (`zig build webrtc-loop`,
`zig build webrtc-bridge-redeem`). The native WebRTC companion accepts generic ICE server records, including
credentialed TURN; provider-specific credential issuance stays with the embedding. Browsers without native sockets use
the byte-transparent relay in Deno, Python, Rust, and Racket. The relay forwards bytes without parsing CapTP or holding
a capability.

The native TCP completion path has held 500,000 authenticated sessions live in one release-mode server process. Each
session completed its signed handshake and fetched a published capability before the measurement barrier. The repeatable
machine, memory, timing, and namespace setup are recorded in [the 1.0 ladder](ladder.md#2-performance-at-scale); the
cheap eight-session form runs under `zig build check` so the two-process harness stays live. Its listener defaults to
`127.0.0.1`; `net.Backend.initWithListenerIp4` selects an interface address or `0.0.0.0` before the backend enters
`TcpLoop`. The loop then exposes the exact kernel-bound IPv4 address and resolved port. A runtime test binds the
wildcard address and reaches it through loopback, while the Darwin build checks the same API against kqueue.

`noise-tcp` and `noise-relay` run ADR-0107's Noise_XK channel on the byte-fed Host and native tiers; `BlockingSession`
refuses both symbols. The optional native relay module composes `ws` and `wss` over one provider, while browser-managed
WebSockets use their runtime's carrier. The remaining secure relay evidence is recorded under
[browser reachability](boundaries.md#browser-reachability).

See [known limitations](boundaries.md#transports-and-peer-identity) for the security and reachability differences
between these choices.

## Actors and hosting

`actors.Vat` adds a Goblins-shaped actor layer above the protocol engine. It supports local actors, eventual sends that
return vows, hosted objects, forwarding, attenuation, and revocation. Optional snapshots and restore apply only to local
actor state; they never rewind a network session.

A Host owns one Vat and gives each session Port its own ingress, so one connection's runaway local work is condemned
without draining a sibling's. Queued turns are admitted under per-ingress budgets
([ADR-0099](decisions/adr/ADR-0099-shared-vat-scheduling.md)).

The same hosting model is available in each language binding. The browser peer can answer a caller over the connection
the call arrived on, so a peer with no listening socket can still receive replies and participate in a handoff.

## Tools and applications

- `zig build` installs the `glowcap` command. It can listen, call, fetch, enliven, run an interactive CapTP lab, serve a
  curated MCP interface, and join a rooms session.
- The rooms, tasks, and tools examples run one server with clients written in several bindings.
- The [Rooms application](../apps/rooms/) exercises browser and terminal peers with durable workspaces. Its chat
  paths cover rooms and direct messages with files, WebRTC and Noise-sealed relay rendezvous, retained room history,
  and member-owned archives read as one combined account
  ([ADR-0144](decisions/adr/ADR-0144-combined-archive-views.md)). IRC edges, directory peering, diagnostics, and
  revocable operator capabilities complete its operating surface. Its archive peer, session peer, and room server run
  Rust with durable identity, TCP/iroh/onion and draining shutdown, the room server answering listener, diagnostic,
  operator and peering capabilities
  and the live timeline as well. Native history supports files and PostgreSQL,
  preserving the existing database schema under one native writer's session lease.
  A live process scenario covers restoration, mutation, restart, writer exclusion
  and queue saturation without losing accepted changes. History admission precedes
  policy changes and upload consumption. The browser UI's HTTP front runs Rust.
  The attached page uses Rust for command classification, bounded retention of unanswered authority requests,
  recovery and retry decisions. Acknowledged commands cannot be replayed by a failed snapshot read.
  Shared attached-session client scenarios cover command/view ordering and
  facet revocation in Wasm and against the native executable over TCP and iroh.
  The native relay shares bounded operator and operations response admission
  with that client. Room inventory rows send at most 32 members plus `membersMore`,
  matching the browser reader rather than exceeding its limit on larger rooms.
  Both standalone IRC entrypoints run Rust. The client front exercises
  independent users and room memberships, Unicode name projection, metadata
  and introduced direct messages over Noise, TCP and iroh. Each user's Rooms
  peer transfers inbox capabilities from one shared public Host. Departure
  retires those capabilities before the IRC connection closes; reusing a
  nickname cannot retarget an old inbox.
  The standalone IRC bridge provides
  TLS/SASL, bounded outbound admission and owned reconnection/shutdown;
  the web launcher, server-test harness and demos
  start the native room server. Its directory publishes before listening and
  preserves both baseline and publication watch reply shapes. Native `rooms-server --irc`
  now composes network/channel leases, room subscriptions, posts and shared
  member identity changes, durable moderator issuance/revocation and one-shot
  invitations. A two-channel CapTP scenario exercises that path, including
  moderator restoration after restart, refusal of revoked held capabilities,
  and observer admission. IRC operator inventories include rooms, stewards and
  membership inboxes; their retirement actions await saved changes. Focused
  checks exercise failed-write preservation, retry, stale IDs, bulk retirement
  and room reset. Durable native authority jobs now have their own bounded
  admission queue and drain before the Host closes. Operator batches retain the
  selected tokens and admit durable acts as capacity becomes available; session
  retirement awaits closure and inventory cleanup. IRC diagnostics reuse the
  operator facts without exposing authority tokens; membership changes update
  the existing session annotation in the live timeline. Uncertain native room
  authority replacements refuse subsequent mutation, including idempotent
  issuance, until restart reloads the document.
  Pending public names exclude native, IRC and foreign creation while an
  authority write waits; a controlled blocking-worker scenario exercises
  reservation, installation and retention after uncertain replacement.
  IRC directory labels use Rooms name equality without IRC punctuation aliases.
  Shared native listener startup restores `onion-key` through each peer's existing
  storage custody before readiness. A real Tor check with networking disabled
  exercises all three binaries across restart and malformed-key refusal, plus
  room calls through the configured local forward port. The web launcher accepts
  native IRC/onion by default; `GLOWCAP_ROOMS_SERVER_BIN` overrides its binary
  path. Subscriber replacement preserves the IRC lease and chosen identity;
  registration-failure scenarios prove rollback through a surviving channel and
  isolation from a newly joined identity. The default HTTP launcher and Compose
  deployment select the native front. Browser test harnesses run TypeScript clients against the native services. The native
  `rooms-web` executable serves assets, supervises the directory and carries
  browser byte traffic. Its process scenarios exercise cancellation, relay
  admission and actual Wasm-to-directory calls over TCP, iroh and local onion
  forwarding. Attachment probes use the local endpoint independently of the
  advertised locator; a process scenario covers attachment, nonownership on
  shutdown and takeover after the external server exits. Native browser
  preparation atomically selects a complete generation containing scripts,
  page, styles, fonts and Wasm. Prepared serving needs no compiler or checkout.
  Native listener changes serialize their durable commits,
  retain accepted work through caller disconnect and drain before shutdown;
  a stalled relay preparation does not hold other listener changes.
  Native room file sends and refiles share
  exclusive staged-upload custody and freeze attachment content before retry
  preparation. Room observations carry their original membership context, and
  join installation checks its exact attempt. Remaining integration and race
  coverage is recorded in [boundaries](boundaries.md).
  The [operating page](../apps/rooms/operating.md) describes what the native session peer answers, and
  `zig build rooms-web-shared-session` attaches two real browser profiles to that peer and proves the
  mirrored member, lines, files, announcements, and issued, paused, and revoked access.
  It ships as source at an exact Git commit. The
  Compose deployment mounts the native artifacts and prepared browser generation,
  records the checkout revision and browser digest after every artifact finishes,
  and refuses to start when either prepared identity differs. The [Rooms page](../apps/rooms/README.md) owns the feature inventory; the
  [development guide](../apps/rooms/developing.md) and [operating guide](../apps/rooms/operating.md) own the runnable
  checks and deployment controls.
- ocapnviz can open a read-only trace sturdyref as a browser OCapN peer. Its production Chromium check covers replay,
  subsequent live observations, and exclusion of the observer session from its own topology. The rooms trace endpoint
  behind that sturdyref admits no socket — viewer or trace producer — without the viz capability the sturdyref carries
  (ADR-0120).
- The accountability example layers signed identity and an audit log above ordinary capabilities without changing CapTP.
  Its three-Host loopback proof redeems a real handoff and attributes the resulting call to the recipient, not the
  introducer.

[`docs/cli.md`](cli.md) is the command-line guide. The [examples](../examples/README.md) and [apps](../apps/README.md)
pages list the programs.

## What checks it

[Stability](stability.md) says which checks run on main and `dev` pushes and pull
requests, and what each one does not prove.
[Community review](community-review.md) is the outside-peer matrix.
