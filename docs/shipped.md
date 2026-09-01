# What ships today

pancake is unreleased, but the library, bindings, transports, and tools below are implemented and checked in this
repository. Outside interoperability is signed CapTP 1.0 over Syrup. Recurring
[Spritely Goblins](https://spritely.institute/goblins/) evidence uses the cleartext `tcp` testing adapter. Read
[known limitations](boundaries.md) before deploying it and [stability](stability.md) for the evidence behind each
support claim.

## Application APIs

| Surface      | What it provides                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Zig          | `driver.Session` connects or listens, fetches and publishes capabilities, calls them, and redeems three-party introductions. `driver.HostRuntime` owns the sessions behind that API.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| I/O-free Zig | `engine.Peer` exposes the protocol engine without sockets or scheduling. Callers feed frames, step the engine, drain output, and handle events.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| C            | Opaque handles, fixed-width result codes, explicit release, and a close that takes a pending-work policy (`PancakeCloseOptions`). Managed frames carry ownership inline without a descriptor allocation or byte copy. Separate archives cover the core, Host, native loop, and transports; every archive exposes a fingerprint derived from reflected functions, public constants, and canonical layout manifests. Binding-projected manifest rows also generate language mirrors, while C-only rows remain out of package APIs. Generated binding loaders compare each fingerprint before ordinary use so a stale companion is refused. Structured diagnostic reports validate stable result codes and consequence shape before crossing into retained storage; fallible blocking transport calls can return their worker-thread diagnostic in caller-owned storage. Every status call begins a fresh archive-local diagnostic fact, so an undetailed refusal cannot inherit an earlier call's cause. |
| Bindings     | Rust, TypeScript, Python, and Racket expose the same session and actor model through the C ABI. They can dial, listen, host objects, call far objects, and pass capabilities.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Browser      | `@pancake/web` runs a full peer in WebAssembly. A browser can host objects, answer calls, redeem handoffs over WebSocket, register for sealed `noise-relay` cold-dials, and hold an ordinary keyed session over WebRTC after signaling.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |

The [Zig examples](../examples/README.md), [C guide](consuming-from-c.md), and [binding contract](../bindings/README.md)
are the entry points for those surfaces.

Binding fronts compose `libpancake_host` and `libpancake_driver`. The driver provides one generic dial/listen/event ABI
over an adopted Host. The TCP provider package owns `noise-tcp`, `keyed-tcp`, and testing `tcp`; separately built
transports register through the common ABI. The iroh provider owns both dial and listener operations, and the onion
archive supplies the standardized Tor transport without teaching the driver its symbol. Zig and all four bindings host
onion through the same Session listener lifecycle as the other providers; only the onion package interprets the
listener's opaque restoration bytes as a Tor service key. An idle Host that is not yet pumping can move into this
runtime in one step: success preserves its identity and capabilities, and a refused transfer leaves the original Host
untouched. After a successful transfer, later setup failure preserves that valid adopted Host for retry. Listener close
preserves sessions already yielded. Wasm and explicitly supplied byte channels use the byte-fed Host instead.

## Protocol

- **Sessions.** pancake negotiates a signed CapTP session and owns its imports, exports, answers, and releases. It
  validates messages before applying them and sends a typed abort when a protocol error requires the session to close.
- **Calls and promises.** Applications can fetch a bootstrap capability, call it, send without waiting, and pipeline
  calls or field, index, and tag projections through an unresolved answer. Pancake accepts the OCapN 1.0 `op:untag`
  operation unconditionally; it sends one only when the partner's signed hello advertises the independent `untag`
  feature, so a silent Goblins peer remains on the proven compatibility set without redefining the version. V1.0
  resolver-only calls retain a typed local answer through the same reply path without fabricating a wire position; every
  `u64` remains available to a partner as an answer position, and wire GC cannot alias the local row. One-way sends use
  the draft's answerless `op:deliver` form; there is no separate `op:deliver-only` operation in the pinned draft or
  Goblins.
- **Persistent references.** A sturdyref is a durable peer-locator plus swiss name that can be enlivened into a live
  capability. Session-level enlivenment checks the complete peer locator before cache lookup or wire traffic; repeated
  enlivenment on that session shares the same import. A mismatched peer or an accepted plain-TCP assertion is refused.
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
  `id` sturdyrefs only when the Host opts into `pancake-next` with `multi_location`; it selects an already authenticated
  same-key session or stages the concrete routes through the pending-dial waist. Host `fetchAt` exposes the same route
  owner for a named publication from a typed locator; applications choose neither CapTP version nor codec for that
  operation.
- **Rooms room-authority generations.** Managed room creation returns a passable manager that governs exactly one
  room's durable entry-link and moderator generations while retaining no live room. Sharing it delegates management;
  discarding a local manager or moderator occurrence does not revoke other copies, and the directory operator can
  recover a lost manager from the room's stable non-bearer management identity. Exact revocation disables copied and
  already-enlivened entry references for new arrivals while preserving memberships that already subscribed. Reissuing
  advances a durable generation and derives unrelated room and moderator sturdyrefs, so old authority stays dead across
  reissue and restart. A durable session checkpoints held manager and moderator sturdyrefs and reconciles online
  retirement and offline restart through the same state-sync reducer. Concurrent recovery joins the original
  result-bearing operation instead of re-entering its Host. A manager may also
  unregister a public name. That retires the public entrance generation and
  moves the room to private access. Current members and independently held
  room, moderator, and manager capabilities remain, so the same manager can
  register the room again if its chosen public name is still available.
- **Rooms entrances and memberships.** A room entrance answers subscription
  with one observer or participant membership capability. Public open rooms
  offer participant memberships. Public moderated rooms offer visible observer
  memberships, and private rooms offer no public entrance. Reusable room links
  offer participant membership without granting management. A participant can
  mint a bounded live invitation for either membership kind. Copies compete
  over one receipt and every retry shares one admission, so only one successful
  subscription can consume it. Native rooms and IRC bridges enforce the same
  one-membership rule.
- **Rooms IRC bridge authority.** An operator-held IRC gateway retains network
  capabilities independently from their channel leases. A network with no
  channels owns no socket. Each channel publication has a source-owned durable
  entry and a separately issued Rooms moderator capability; the native
  directory cannot forge either. Parting retires both live publications, and
  recreation receives a fresh generation. Bridge moderation removes Rooms
  memberships and explicitly carries no IRC operator privilege.
- **Rooms directory peering.** A separately published peering capability adds bounded foreign-room generations to a
  directory and returns exact revocation leases. Each listing belongs to its publisher's destination Session: exact
  revoke or disconnect removes discovery, while already-handed room references stay live. A source with several
  listeners authors one complete room link; verified enlivenment retains that same canonical route for the later give,
  with no second advertisement RPC or application-side locator reconstruction. Its `id` route carries iroh and Noise
  paths prove the key under `via`, while onion and baseline socket paths remain weak `alt-locators`. The recurring
  server suite proves profile-gated route advertisement, TCP directory peering, exact revocation, and continued use of
  references already handed out. An on-demand iroh scenario additionally publishes through an identity route and redeems
  through its weak TCP fallback when the destination has no iroh provider. `zig build goblins-rooms-peering` proves the
  product composition with a real v1.0/Syrup Goblins member through revoke and continued use. Servers without
  `--peering` publish no such authority.
- **Three-party handoff.** A capability received from one peer can be returned or passed recursively to another. Inbound
  signed gives become Host-owned promises immediately. Outbound foreign objects and promises wait as one bounded
  transaction until every gift id, exporter deposit, shared promise listener, recipient escrow, and rewritten message
  can commit. Core and C Host cover terminal failure. Node-local routes use an explicit reference arm, so every `u64`
  remains available to a peer as a wire import and an unlowered route is structurally refused by codecs. The recurring
  Deno, Python, Rust, and Racket gifter matrix proves two nested gives against live Goblins.

- **Relayed promise settlement.** When a shared home promise settles, its complete Passable value crosses Host identity
  once. Each recipient reuses the bounded Passable transaction. Nested objects become gives, and nested promises become
  successor proxies. A recipient that cannot admit its projection breaks without publishing a prefix. No sibling rolls
  back. The live Goblins evidence covers both directions. A Goblins recipient reads pancake's relayed give. In the
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
  can deadlock the other. The C Host and every binding expose both ledgers through one versioned, named session-limit
  options value; zero fields preserve the current Host policy, and already-minted peers keep their snapshot. Distributed
  garbage collection is available as a per-session opt-in in every binding: fetched capabilities, fulfilled far results,
  and recursively nested delivered arguments all return their opaque Host retain through one finalizer seam. A final
  import release also clears sturdyref cache state and makes every old host route fail closed before the partner may
  reuse that position.
- **Unreturned failures.** The vendor-neutral diagnostics layer and `PancakeContext` provide one typed, bounded journal
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
  close barrier. The policy ships on the Zig Host, the C ABI (`pancake_host_close`, `pancake_host_close_progress`, and
  `pancake_host_lifecycle_state`), the driver loop, and all four language bindings. Failures stay ordered on the owner
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
| Cap'n Proto | pancake-to-pancake, with checked golden frames. Goblins speaks Syrup.                                |

The authenticated OCapN 1.0 profile uses Syrup. Two pancake peers can prefer Cap'n Proto or `"pancake-next"`. Each side
puts that offer in the hello's locator hints, and `engine.Peer.settleNegotiatedProfile` settles the pair after both
verified hellos arrive. [ADR-0103](decisions/adr/ADR-0103-hello-carried-profile-offers.md) records that handshake. An
absent offer is the v1.0/Syrup floor, so Goblins traffic stays wire-identical. Over onion the offer is sent only when
the partner is known to be pancake, because the pinned Goblins cannot dial a hinted onion locator. A dial includes the
offer when it was handed the pancake-hinted address form. An accept includes it when answering a hello that already
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

`onion` is the draft's transport and the one Goblins ships. Live Goblins also meets pancake over `tcp` and `iroh`
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

- `zig build` installs the `pancake` command. It can listen, call, fetch, enliven, run an interactive CapTP lab, serve a
  curated MCP interface, and join a rooms session.
- The rooms, tasks, and tools examples run one server with clients written in several bindings.
- The [Rooms application](../apps/rooms/) exercises browser and terminal peers with durable workspaces. Each held
  directory has a command view of its own (`/directory`), not a chat: tab commands run there and their results stay in
  that view. Its chat paths
  cover room and direct-message files, WebRTC, Noise-sealed relay rendezvous, retained room history, and member-owned
  archives. IRC edges, peering, diagnostics, and revocable operator capabilities complete its operating surface. A
  local browser session can Share from Settings for the life of the tab. The Share capability names the hosting tab's
  directory, so another browser can Attach from a different Rooms page without the hosting tab joining theirs.
  Closing or reloading that tab ends sharing. The
  Compose deployment starts one durable user workspace beside the room directory under separate custody, exposes no new
  port or session-root HTTP endpoint, and prints its bearer authorities in one operator handoff after both peers are
  ready. The prerelease distribution is source at an exact Git commit; its Compose image is the pinned Deno runtime and
  mounts that checkout with native artifacts built from the same commit rather than claiming to be a standalone Rooms
  image. Online authority and reach changes commit through the shared session owner and reach attached views immediately;
  disconnected local intent is retained, then reconciled lazily with exact-generation retirement on reconnect. A
  retired exact room link remains a manual recovery state: public rooms rejoin by name only after an explicit choice,
  private rooms require a current link, and a failed attempt restores the prompt rather than enabling background retry.
  Settings places locators under Reachability and separates Session state from
  live and saved authority under Holdings. Holdings covers room entry, archive
  peers, and independently revocable archive-peer shares. It also covers
  operations capabilities, the attached-session facet, and access grants.
  Session remains about storage ownership and retention policy. A conversation
  card can hand a live one-shot archive facet or offer a durable archive-peer
  share over a direct line. That pipe can carry a room or standing account
  whose facet scope is independent of the DM.
  The
  first-read page owns that feature inventory. The [development guide](../apps/rooms/developing.md) and
  [operating guide](../apps/rooms/operating.md) own the runnable checks and deployment controls.
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

`zig build check` is the in-tree check: it runs the tests, examples, architecture checks, committed protocol fixtures,
and allocation and footprint budgets, and it compiles the live-interop drivers. It does not run an outside protocol
implementation.

`zig build check-external` runs the core outside-authority baseline: the upstream OCapN suite, live Goblins sessions in
both call directions and all three handoff roles, and pinned-source findings. It also regenerates the Syrup corpus with
the upstream encoder. The recurring [`ci/gates.sh`](../ci/gates.sh) sequence runs that evidence plus each language
binding as a live Goblins client through the C ABI and the Deno binding as a host. Those steps require their named
external runtimes and are not evidence supplied by `zig build check`.

The three-peer rooms checks are on-demand: a pancake browser tab redeems a room's introduction and holds a direct
message with a real Goblins vat, off the room's path, over cleartext TCP and encrypted QUIC. They require Chromium and
therefore do not run in the recurring sequence.

[Stability](stability.md) says which checks run on main and dev pushes and pull requests.
[Community review](community-review.md) records exactly what the outside-peer checks do and do not prove.
