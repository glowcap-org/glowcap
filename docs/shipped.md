# What ships today

pancake is unreleased, but the library, bindings, transports, and tools below
are implemented and checked in this repository. This is the short inventory.
Read [known limitations](boundaries.md) before deploying it and
[stability](stability.md) for the evidence behind each support claim.

## Application APIs

| Surface | What it provides |
| --- | --- |
| Zig | `driver.Session` connects or listens, fetches and publishes capabilities, calls them, and redeems three-party introductions. `driver.PollHost` owns the sessions behind that API. |
| Sans-I/O Zig | `engine.Peer` exposes the protocol engine without sockets or scheduling. Callers feed frames, step the engine, drain output, and handle events. |
| C | Opaque handles, fixed-width result codes, explicit release, and separate archives for the core, host, and transports. |
| Bindings | Rust, TypeScript, Python, and Racket expose the same session and actor model through the C ABI. They can dial, listen, host objects, call far objects, and pass capabilities. |
| Browser | `@pancake/web` runs a full peer in WebAssembly. A browser can host objects, answer calls, and redeem handoffs over WebSocket; after signaling, it can also hold an ordinary keyed session over WebRTC. |

The [Zig examples](../examples/README.md), [C guide](consuming-from-c.md), and
[binding contract](../bindings/README.md) are the entry points for those
surfaces.

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
  any new connection redemption needs. A deposited local gift keeps the exact
  actor in the Host Vat, so alias replacement cannot redirect it
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)).
  Zig and the bindings can also listen for settlement of a promise received
  from a peer
  ([ADR-0095](decisions/adr/ADR-0095-listening-on-a-received-promise.md)).
- **Handoff ownership.** Gifts live on the Gifter–Exporter `Peer`. Accepted
  replay counters live on the Receiver–Exporter `Peer`. An early withdrawal is
  verified against the still-open gifter session before it waits for the
  deposit. After that session closes with no replacement reusing its names, a
  later withdrawal fails closed
  ([ADR-0100](decisions/adr/ADR-0100-session-owned-handoff-authority.md)).
  Product Hosts (`PollHost`, the C Host, and the bindings) mint a fresh session
  signing key per connection
  ([ADR-0097](decisions/adr/ADR-0097-captp-session-identity-attestation.md)).
  A bare byte-fed Host that omits `Options.session_seeds` still defaults to the
  durable seed, which can recreate those names across reconnect. Next-profile
  emitted counters stay session-owned; automatic V1 redemption counts up for
  the Node lifetime so Goblins reconnect stays compatible.
- **Identity.** A session can report the identity its handshake established. On
  `driver.Session`, the C ABI, Wasm, and the bindings, every application
  capability is one opaque Host-scoped identity
  ([ADR-0096](decisions/adr/ADR-0096-host-scoped-capability-identity.md)).
  Identities lift from fetches, replies, delivered arguments, enlivenment,
  publication, and handoff. Wire positions surface only on the low-level
  `engine.Peer` and `BlockingSession` tiers.
- **Publication.** Each session reaches the Host's shared Vat through its own
  Port. Publishing, replacing, or removing an alias changes discovery only.
  Issued capabilities and deposited gifts keep the exact actor, whose local
  identity survives Port closure. An actor lives exactly as long as its roots
  (aliases, capability handles, export bindings, and exact gifts) and is
  reclaimed when the last one releases
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)).
  Durable publication is a separate namespace
  ([ADR-0098](decisions/adr/ADR-0098-sturdyref-peer-authority.md)).
  The Host mints an unpredictable versioned swiss name a mutable alias cannot
  claim, never reassigns it, and returns the complete sturdyref. Removal makes
  the old sturdyref miss without revoking issued capabilities. Native
  enlivenment selects a live matching session or dials the sturdyref peer
  itself.
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
binding exposes the host preference selector. Each of `zig build rust-dogfood`,
`deno-dogfood`, `python-dogfood`, and `racket-dogfood` exercises the C ABI as a
real consumer over a live Cap'n Proto socket. Zig applications can add another
codec through the open registry without changing the protocol core.

## Transports

| Transport | Use |
| --- | --- |
| `tcp` | Plain TCP and the broadest interop path. It is cleartext. |
| `keyed-tcp` | TCP with a key designator as the dial target. The channel is cleartext and unauthenticated; the key does not prove possession. |
| `keyed-relay` | Cleartext WebSocket to a relay; the key designator is a dial target with no listening address. Trusted network and relay only. |
| `inproc` | An in-process connection for tests and deterministic local scenarios. |
| `iroh` | Encrypted QUIC with discovery, relays, and a node ID that also serves as the OCapN designator. |
| `webrtc` | An encrypted DataChannel reached through signaling. It carries a normal keyed OCapN session once the channel is open. |

TCP, iroh, and WebRTC have Host completion-loop integrations. A native WebRTC
resident owns one shared runtime and readiness fd for stable peer-id open,
candidate, readable, writable, and closed events; its public C family uses
non-blocking try-I/O. The explicit blocking connection remains available for
`BlockingSession`. A bare `webrtc` locator still cannot dial without configured
signaling authority; with that authority the Host adopts the DataChannel and
continues handoff redemption (`zig build webrtc-loop`,
`zig build webrtc-bridge-redeem`). Browsers that cannot open native sockets can
also use the byte-transparent relay shipped in Deno, Python, Rust, and Racket.
The relay forwards bytes without parsing CapTP or holding a capability.

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
- The accountability example layers signed identity and an audit log above
  ordinary capabilities without changing CapTP.

[`docs/cli.md`](cli.md) is the command-line guide. The
[examples](../examples/README.md) and [apps](../apps/README.md) pages list the
programs.

## What checks it

`zig build check` runs the in-tree tests, examples, architecture checks,
protocol fixtures, and allocation and footprint budgets. The upstream OCapN
suite runs against a pancake peer, and the Goblins checks hold live sessions in
both call directions and all three handoff roles. Each language binding also
runs a live Goblins client through the C ABI. One check puts three
implementations at the three corners of a single handoff: a browser tab redeems
a room's introduction and holds a direct message with a real Goblins vat, off
the room's path, over cleartext TCP and over encrypted QUIC alike.

[Stability](stability.md) says which checks run on every push.
[Community review](community-review.md) records exactly what the outside-peer
checks do and do not prove.
