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

- **Sessions.** pancake negotiates an authenticated CapTP session and owns its
  imports, exports, answers, and releases. It validates messages before
  applying them and sends a typed abort when a protocol error requires the
  session to close.
- **Calls and promises.** Applications can fetch a bootstrap capability, call
  it, send without waiting, and pipeline calls or field, index, and tag
  projections through an unresolved answer.
- **Persistent references.** A sturdyref is a durable peer-locator plus swiss
  name that can be enlivened into a live capability. Session-level enlivenment
  checks the complete peer locator before
  cache lookup or wire traffic; repeated enlivenment on that session shares the
  same import. A mismatched peer or an accepted plain-TCP assertion is refused.
- **Three-party handoff.** A capability received from one peer can be returned
  to another. pancake handles the deposit, signed gift, withdrawal, and new
  connection choreography behind the application API. A deposited local gift
  retains the exact actor in the Host's actor runtime (its Vat), so later alias
  replacement cannot redirect it. A withdrawal that arrives first is verified
  against the still-open gifter session before it waits for the deposit. Gifts
  belong to the Gifter–Exporter `Peer`; accepted and emitted replay counters
  belong to the Receiver–Exporter `Peer` carrying those receives and
  withdrawals. Each is destroyed with its owning session. A later withdrawal
  fails closed while no replacement connection has
  reused the same session names. Host key reuse does not yet isolate reconnect
  incarnations: an old signed receive can resolve against a replacement session
  and consume its later same-id deposit. [ADR-0097](decisions/adr/ADR-0097-captp-session-identity-attestation.md)
  owns the fresh-session-key work. Native Zig can also listen for the settlement
  of a promise received from a peer.
- **Identity and publication.** A session can report the identity established
  by its handshake. Native Zig's owning `driver.Session`, the C ABI, Wasm, and
  the language bindings all represent every application capability as one
  opaque Host-scoped identity. Identities are lifted from fetches, replies,
  delivered arguments, enlivenment, publication, and handoff. Wire positions
  surface only on the explicit low-level `engine.Peer` and `BlockingSession`
  tiers.
  The Vat owned by a Host is projected through a Port for each session; each
  Port is that session's adapter to the shared actor graph. Publication is lazy
  discovery: an alias can be published, replaced, or removed, and each change
  moves discovery only — issued capabilities and deposited gifts keep the
  exact actor, whose local identity survives Port closure. An actor lives
  exactly as long as its roots — aliases, capability handles, export
  bindings, exact gifts — and is reclaimed when the last one releases
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)).
  Durable publication is a separate namespace
  ([ADR-0098](decisions/adr/ADR-0098-sturdyref-peer-authority.md)): the Host
  mints an unpredictable versioned swiss name a mutable alias structurally
  cannot claim, never reassigns it, and returns the complete sturdyref;
  removal makes the old sturdyref miss while issued capabilities keep the
  actor. Native enlivenment selects a live matching session or dials the
  sturdyref peer itself.
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

The authenticated OCapN 1.0 profile uses Syrup. Native pancake peers can
negotiate the Cap'n Proto profile and fall back to Syrup. Zig applications can
add another codec through the open registry without changing the protocol core.

## Transports

| Transport | Use |
| --- | --- |
| `tcp` | Plain TCP and the broadest interop path. It is cleartext. |
| `keyed-tcp` | TCP with a designator bound to the CapTP handshake key. It authenticates the peer but does not encrypt the channel. |
| `inproc` | An in-process connection for tests and deterministic local scenarios. |
| `iroh` | Encrypted QUIC with discovery, relays, and a node ID that also serves as the OCapN designator. |
| `webrtc` | An encrypted DataChannel reached through signaling. It carries a normal keyed OCapN session once the channel is open. |

TCP, iroh, and WebRTC have Host completion-loop integrations. A native WebRTC
resident owns one shared runtime and readiness fd for stable peer-id open,
candidate, readable, writable, and closed events; its public C family uses
non-blocking try-I/O. The explicit blocking connection remains available for
`BlockingSession`, but a bare locator still cannot supply signaling authority or
enter the generic Host loop. Browsers that cannot open native sockets can also
use the byte-transparent relay shipped in Deno, Python, Rust, and Racket. The
relay forwards bytes without parsing CapTP or holding a capability.

See [known limitations](boundaries.md#transports-and-peer-identity) for the
security and reachability differences between these choices.

## Actors and hosting

`actors.Vat` adds a Goblins-shaped actor layer above the protocol engine. It
supports local actors, eventual sends that return vows, hosted objects,
forwarding, attenuation, and revocation. Optional snapshots and restore apply
only to local actor state; they never rewind a network session.

Queued local turns are attributed to an actor-layer ingress. Admission checks
per-ingress turn and owned-byte limits before cloning, returns a typed
`ResourceExhausted` refusal atomically, and stores messages in independently
reclaimable chunks. Budgeted Vat drives rotate fairly while preserving FIFO
within each ingress. The warmed local queue path is allocation-free; one
Vat-wide spare retains at most 4 KiB of payload capacity. A Host owns one Vat
and gives each session Port its own ingress; Host batch drives stay within that
ingress's budget so one connection's runaway local work is condemned without
draining a sibling's.

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
runs a live Goblins client through the C ABI.

[Stability](stability.md) says which checks run on every push.
[Community review](community-review.md) records exactly what the outside-peer
checks do and do not prove.
