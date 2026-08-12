# What ships today

pancake is unreleased, but the library, bindings, transports, and tools below
are implemented and checked in this repository. Read
[known limitations](boundaries.md) before deploying it and
[stability](stability.md) for the evidence behind each support claim.

## Application APIs

| Surface | What it provides |
| --- | --- |
| Zig | `driver.Session` connects or listens, fetches and publishes capabilities, calls them, and redeems three-party introductions. `driver.HostRuntime` owns the sessions behind that API. |
| Sans-I/O Zig | `engine.Peer` exposes the protocol engine without sockets or scheduling. Callers feed frames, step the engine, drain output, and handle events. |
| C | Opaque handles, fixed-width result codes, explicit release, and separate archives for the core, host, native loop, and transports. |
| Bindings | Rust, TypeScript, Python, and Racket expose the same session and actor model through the C ABI. They can dial, listen, host objects, call far objects, and pass capabilities. |
| Browser | `@pancake/web` runs a full peer in WebAssembly. A browser can host objects, answer calls, and redeem handoffs over WebSocket; after signaling, it can also hold an ordinary keyed session over WebRTC. |

The [Zig examples](../examples/README.md), [C guide](consuming-from-c.md), and
[binding contract](../bindings/README.md) are the entry points for those
surfaces.

Native binding fronts compose `libpancake_host` and `libpancake_driver`. The
driver provides one generic dial/listen/event ABI over an adopted Host. The TCP
provider package owns `tcp`, `keyed-tcp`, and `noise-tcp`; separately built
transports register through the common ABI. The iroh provider owns both dial
and listener operations, and the onion archive supplies the standardized Tor
transport without teaching the driver its symbol. An idle Host that is not yet
pumping can move into this runtime in one step: success preserves its identity
and capabilities, and failure leaves the original Host untouched. Listener
close preserves sessions already yielded. Wasm and explicitly supplied byte
channels use the byte-fed Host instead.

## Protocol

- **Sessions.** pancake negotiates a signed CapTP session and owns its
  imports, exports, answers, and releases. It validates messages before
  applying them and sends a typed abort when a protocol error requires the
  session to close.
- **Calls and promises.** Applications can fetch a bootstrap capability, call
  it, send without waiting, and pipeline calls or field, index, and tag
  projections through an unresolved answer.
- **Persistent references.** A sturdyref is a durable peer-locator plus swiss
  name that can be enlivened into a live capability. Session-level enlivenment
  checks the complete peer locator before cache lookup or wire traffic;
  repeated enlivenment on that session shares the same import. A mismatched
  peer or an accepted plain-TCP assertion is refused.
- **Three-party handoff.** A capability received from one peer can be returned
  to another. The application API covers deposit, signed gift, withdrawal, and
  any new connection redemption needs. Deposited gifts keep the exact actor in
  the Host Vat
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)).
  Zig and the bindings can also listen for settlement of a promise received
  from a peer
  ([ADR-0095](decisions/adr/ADR-0095-listening-on-a-received-promise.md)).
  Gifts and replay counters live on the sessions that own them; product Hosts
  mint a fresh signing key per session
  ([ADR-0100](decisions/adr/ADR-0100-session-owned-handoff-authority.md),
  [ADR-0097](decisions/adr/ADR-0097-captp-session-identity-attestation.md)).
- **Identity.** A session can report the identity its handshake established.
  On `driver.Session`, the C ABI, Wasm, and the bindings, every application
  capability is one opaque Host-scoped identity
  ([ADR-0096](decisions/adr/ADR-0096-host-scoped-capability-identity.md)).
  Wire positions surface only on the low-level `engine.Peer` and
  `BlockingSession` tiers.
- **Publication.** Each session reaches the Host's shared Vat through its own
  Port. Publishing changes discovery only; issued capabilities and deposited
  gifts keep the exact actor until their roots release
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)).
  Durable publication is a separate namespace
  ([ADR-0098](decisions/adr/ADR-0098-sturdyref-peer-authority.md)): the Host
  mints an unpredictable swiss name, never reassigns it, and returns the
  complete sturdyref. Native enlivenment selects a live matching session or
  dials the sturdyref peer itself.
- **Locators.** Zig, C, and the bindings parse and format `ocapn://` peer and
  sturdyref URIs. Applications dial through a locator rather than a
  transport-specific session API.
- **Resource limits.** Session tables, projection depth, nesting depth, and
  Cap'n Proto traversal are bounded. Distributed garbage collection is
  available as an opt-in for fetched references. A final import release also
  clears sturdyref cache state and makes every old host route fail closed
  before the partner may reuse that position.

The passable-value model covers the OCapN values used by the current protocol,
plus the Set and Keyword forms used by Goblins. OCapN Null is not implemented;
see [protocol limitations](boundaries.md#protocol-and-interop).

## Codecs

| Codec | Use |
| --- | --- |
| Syrup | The interoperable OCapN wire format. Its fixtures are cross-checked against upstream Syrup encoders. |
| Cap'n Proto | A pancake-to-pancake format with checked golden frames. It is not a Goblins format. |

The authenticated OCapN 1.0 profile uses Syrup. A pancake pair can prefer Cap'n
Proto or `"pancake-next"`; each side states its offer in the hello's locator
hints, and `engine.Peer.settleNegotiatedProfile` settles the pair after both
verified hellos arrive
([ADR-0103](decisions/adr/ADR-0103-hello-carried-profile-offers.md)). An absent
offer is the v1.0/Syrup floor, so Goblins traffic stays wire-identical. Every
binding exposes the host preference selector. Binding checks
(`zig build rust-dogfood`, `deno-dogfood`, `python-dogfood`, and
`racket-dogfood`) exercise the C ABI as a real consumer over a live Cap'n Proto
socket. Zig applications can add another codec through the open registry
without changing the protocol core.

## Transports

| Transport | Use |
| --- | --- |
| `tcp` | Plain TCP and the broadest interop path. It is cleartext. |
| `keyed-tcp` | TCP with a key designator as the dial target. The channel is cleartext and unauthenticated; the key does not prove possession. |
| `noise-tcp` | The keyed-tcp grammar with ADR-0107's sealed channel on the wire: a Noise_XK handshake between the two peers encrypts the channel end to end, and completing it proves the dialed key. The Zig host tiers, C driver loop, and all four native bindings dial and listen on it. |
| `keyed-relay` | Cleartext WebSocket to a relay; the key designator is a dial target with no listening address. Trusted network and relay only. |
| `noise-relay` | The keyed-relay pipe with ADR-0107's sealed channel: CapTP peers run Noise_XK with each other, and the relay only forwards ciphertext. The native provider dials and registers through the generic driver, every native binding composes that provider, and browser wasm rendezvous reports authenticated transport provenance. |
| `inproc` | An in-process connection for tests and deterministic local scenarios. |
| `iroh` | Encrypted QUIC with discovery, relays, and a node ID that also serves as the OCapN designator. |
| `webrtc` | An encrypted DataChannel reached through signaling. It carries a normal keyed OCapN session once the channel is open. |
| `onion` | The standardized OCapN Tor netlayer. A version 3 service id addresses an encrypted, location-hiding circuit; Tor proves the service to the dialer but reveals no caller identity to the listener. |

`onion` is the draft's transport and the one Goblins ships. Live Goblins also
meets pancake over `tcp` and `iroh` through adapters in
`conformance/goblins-peer/`. In-tree onion checks use fake SOCKS and control
daemons under `zig build check`. Live Tor proofs are `onion-interop`,
`goblins-onion`, `ocapn-conformance-onion`, `bindings-onion`, and
`demo-rooms-onion`. See [stability](stability.md) and
[known limitations](boundaries.md).

TCP, iroh, WebRTC, and relay transports integrate with the generic Host driver.
A relay locator can carry its `rendezvous-relay` route, with deployment
configuration retained only as the fallback for a bare locator.
A bare `webrtc` locator needs configured signaling authority
(`zig build webrtc-loop`, `zig build webrtc-bridge-redeem`). Browsers without
native sockets use the byte-transparent relay in Deno, Python, Rust, and
Racket. The relay forwards bytes without parsing CapTP or holding a capability.

`noise-tcp` and `noise-relay` run ADR-0107's Noise_XK channel on the byte-fed
Host and native tiers; `BlockingSession` refuses both symbols.

See [known limitations](boundaries.md#transports-and-peer-identity) for the
security and reachability differences between these choices.

## Actors and hosting

`actors.Vat` adds a Goblins-shaped actor layer above the protocol engine. It
supports local actors, eventual sends that return vows, hosted objects,
forwarding, attenuation, and revocation. Optional snapshots and restore apply
only to local actor state; they never rewind a network session.

A Host owns one Vat and gives each session Port its own ingress, so one
connection's runaway local work is condemned without draining a sibling's.
Queued turns are admitted under per-ingress budgets
([ADR-0099](decisions/adr/ADR-0099-shared-vat-scheduling.md)).

The same hosting model is available in each language binding. The browser peer
can answer a caller over the connection the call arrived on, so a peer with no
listening socket can still receive replies and participate in a handoff.

## Tools and applications

- `zig build` installs the `pancake` command. It can listen, call, fetch,
  enliven, run an interactive CapTP lab, serve a curated MCP interface, and
  join a rooms session.
- The rooms, tasks, and tools examples run one server with clients written in
  several bindings.
- The rooms application exercises browser peers, direct messages, WebRTC, and
  relay rendezvous.
- ocapnviz can open a read-only trace sturdyref as a browser OCapN peer. Its
  production Chromium check covers replay, subsequent live observations, and
  exclusion of the observer session from its own topology.
- The accountability example layers signed identity and an audit log above
  ordinary capabilities without changing CapTP.

[`docs/cli.md`](cli.md) is the command-line guide. The
[examples](../examples/README.md) and [apps](../apps/README.md) pages list the
programs.

## What checks it

`zig build check` is the in-tree check: it runs the tests, examples,
architecture checks, committed protocol fixtures, and allocation and footprint
budgets, and it compiles the live-interop drivers. It does not run an outside
protocol implementation.

`zig build check-external` runs the core outside-authority baseline: the
upstream OCapN suite, live Goblins sessions in both call directions and all
three handoff roles, and pinned-source findings. It also regenerates the Syrup
corpus with the upstream encoder. The every-push
[`ci/gates.sh`](../ci/gates.sh) sequence runs that evidence plus each language
binding as a live Goblins client through the C ABI and the Deno binding as a
host. Those steps require their named external runtimes and are not evidence
supplied by `zig build check`.

The three-implementation rooms checks are on-demand: a browser tab redeems a
room's introduction and holds a direct message with a real Goblins vat, off the
room's path, over cleartext TCP and encrypted QUIC. They require Chromium and
therefore do not run in the every-push sequence.

[Stability](stability.md) says which checks run on every push.
[Community review](community-review.md) records exactly what the outside-peer
checks do and do not prove.
