---
type: living
description: Everything glowcap implements and checks in this repository.
sources: []
---

# What ships

Everything on this page is implemented in this repository, and
[What you can depend on](stability.md) says how each part is checked. glowcap speaks signed CapTP 1.0 over Syrup to
outside implementations, and most of its regular checks against
[Spritely Goblins](https://spritely.institute/goblins/) use the cleartext `tcp`
testing adapter.

Read [known limitations](boundaries.md) before deploying. If capabilities are new to you, [capabilities](capabilities.md) starts from zero.

glowcap speaks two wire profiles. `1.0` is pinned to what Goblins ships, and
is the profile those regular checks exercise. `next` tracks current OCapN
direction: it uses the merged five-operand delivery, deliver-only, and integer
listen modes, refuses the removed projection operations, and keeps the
Goblins-compatible hello and crypto representations. The
[conformance manifest](ocapn-conformance.md) says which draft sections each
profile has adopted, deferred, or left pending, and the recurring next
conformance lane checks `next` beside the unchanged `1.0` suite
([ADR-0065](decisions/adr/ADR-0065-next-profile-operations.md)).

## Application APIs

| Surface      | What it provides |
| ------------ | ---------------- |
| Zig          | `driver.Session` connects or listens, fetches and publishes capabilities, calls them, and redeems three-party introductions. `driver.HostRuntime` owns the sessions behind that API. |
| I/O-free Zig | `engine.Peer` exposes the protocol engine without sockets or scheduling. Callers feed frames, step the engine, drain output, and handle events. |
| C            | Opaque handles, fixed-width result codes, explicit release, and separate archives for the core, Host, driver loop, and transports. See [the C ABI](#the-c-abi) below. |
| Bindings     | Rust, TypeScript, Python, and Racket expose the same session and actor model through the C ABI. They can dial, listen, host objects, call far objects, and pass capabilities. |
| Browser      | `@glowcap/web` runs a full peer in WebAssembly. A browser can host objects, answer calls, redeem handoffs, take sealed `noise-relay` cold dials, and dial or answer a keyed session over WebRTC. |

The [Zig examples](../examples/README.md), [C guide](consuming-from-c.md), and [binding contract](../bindings/README.md)
are the entry points for those surfaces.

### The C ABI

- **Closing.** A close takes a policy for pending work (`GlowcapCloseOptions`).
- **Frames.** Managed frames carry their ownership inline, with no descriptor allocation and no byte copy.
- **Version checks.** Every archive exposes a fingerprint of its functions, constants, and layouts. Binding loaders
  compare it before use, so a stale companion library is refused.
- **Diagnostics.** Each status call starts a fresh structured diagnostic, so a refusal never inherits an earlier
  call's cause.

### How the bindings run

The bindings combine `libglowcap_host` and `libglowcap_driver`. The driver offers one generic ABI for dialing,
listening, and events, over a Host it has adopted.

- The TCP provider package handles `noise-tcp`, `keyed-tcp`, and the testing `tcp`. Other transports register
  through the same ABI.
- The iroh provider dials and listens. Zig uses `iroh.MultiplexedAdapter` with `driver.connect` and
  `driver.listen`.
- The onion archive supplies the standard Tor transport. Zig and all four bindings host onion like any other
  provider, and only the onion package reads the Tor service key it stores.
- An idle Host can move into the driver in one step and keep its identity and capabilities. A refused move leaves
  it untouched.
- Closing a listener keeps the sessions it already handed out.
- Wasm and caller-supplied byte channels use the byte-fed Host instead of the driver.

## Protocol

- **Sessions.** glowcap negotiates a signed CapTP session and owns its imports, exports, answers, and releases. It
  validates every message before applying it and sends a typed abort when an error closes the session.
- **Calls and promises.** Applications fetch a bootstrap capability, call it, send without waiting, and pipeline
  calls through an unresolved answer. The `1.0` profile also supports field, index, and tag projections over
  that answer. Next refuses those wire projection operations. Calls and listeners wait through chains of
  local promises until their requested result is available ([ADR-0003](decisions/adr/ADR-0003-promise-pipelining-and-listeners.md)). A failed turn withdraws its sends,
  including staged introductions ([ADR-0058](decisions/adr/ADR-0058-transactional-turn-sends.md)).
  glowcap accepts OCapN 1.0 `op:untag` from any peer and sends it only to a partner that advertises the `untag`
  feature.
- **Persistent references.** A sturdyref is a durable peer locator plus a swiss number. Enlivening one checks the
  whole peer locator before any traffic and refuses a mismatched peer or an accepted plain-TCP assertion. Repeated
  enlivening on a session shares one import.
- **Multi-home peers.** An `id` locator names a peer's durable key and lists routes that must prove it. Redeem races
  two proved routes in order and keeps the first. `alt-locators` are weaker fallbacks tried one at a time.
  [Multi-home peers](https://glowcap.org/multihome/) explains the design, and
  [known limitations](boundaries.md#protocol-and-interop) gives the rules.
- **Distributed garbage collection.** Zig and all four bindings release Goblins objects independently and
  observe Goblins reclaim them. Rust releases on drop by default, set on the Host. TypeScript, Python, and Racket
  keep a per-session opt-in.
- **Three-party handoff.** A capability from one peer can be passed on to another, recursively. Outbound gives wait
  as one bounded transaction and keep their place in the recipient's queue. The Deno, Python, Rust, and Racket
  matrix proves nested gives against live Goblins, with Goblins in the gifter and exporter roles too
  ([ADR-0039](decisions/adr/ADR-0039-session-owned-handoff.md),
  [ADR-0039](decisions/adr/ADR-0039-session-owned-handoff.md)).
- **Promise settlement across peers.** A shared promise's settled value reaches every recipient once, with nested
  objects becoming gives. Zig and the bindings can listen on a promise received from a peer
  ([ADR-0003](decisions/adr/ADR-0003-promise-pipelining-and-listeners.md)).
- **Identity.** A session reports the identity its handshake established. Every application capability is one
  opaque Host-scoped identity, including a target reached both directly and through a handoff. Each binding
  compares them with its own equality ([ADR-0026](decisions/adr/ADR-0026-host-scoped-capability-identity.md),
  [ADR-0028](decisions/adr/ADR-0028-session-and-durable-peer-authentication.md)).
- **Publication.** Publishing a name changes discovery only. Issued capabilities keep their actor until released
  ([ADR-0014](decisions/adr/ADR-0014-actor-execution-and-lifetime.md)). Durable publication mints an unpredictable
  swiss number and returns the full sturdyref
  ([ADR-0007](decisions/adr/ADR-0007-sturdyrefs-and-publication.md),
  [ADR-0007](decisions/adr/ADR-0007-sturdyrefs-and-publication.md)).
- **Locators.** Zig, C, and the bindings parse and format `ocapn://` peer and sturdyref URIs. Host `fetchAt` takes a
  locator and a name, so the application never picks a CapTP version or codec.
- **Resource limits.** Frames, session tables, retained answer bytes, nesting depth, and Cap'n Proto traversal are
  bounded. One partner's backpressure holds back only its own work
  ([ADR-0017](decisions/adr/ADR-0017-outbound-pressure-and-fairness.md)). Every binding sets these limits through
  one versioned options value.
- **Busy-poll.** A Zig `HostRuntime` given a busy-poll window spins and reaps
  its transports before it parks, so a reply that lands inside the window
  costs no wake
  ([ADR-0060](decisions/adr/ADR-0060-completion-submission-and-parking.md)).
- **One wake per reply on io_uring.** When every transport on a
  `HostRuntime` has its own kernel queue, the idle thread waits inside the
  first one's queue, and that queue also watches the other wake sources. A
  reply then wakes the thread once instead of twice.
  A receive set up again during a call goes out with the next wait, so a call
  that only read its reply makes no system call as it returns
  ([ADR-0060](decisions/adr/ADR-0060-completion-submission-and-parking.md)).
- **Unreturned failures.** A failure with no caller left to receive it goes into a typed, bounded log on the
  `GlowcapContext` ([ADR-0031](decisions/adr/ADR-0031-structured-diagnostics.md)).
- **Close.** Every owner closes under an explicit policy: cancel now, or finish admitted work within a grace period
  ([ADR-0030](decisions/adr/ADR-0030-failure-and-close-policy.md)). This works on the Zig Host, the C ABI, the
  driver loop, and all four bindings. Close reports the first failure, a bounded list of the rest, and their count.
  A second close waits on the first.

The value model covers the pinned OCapN scalar and aggregate forms, including big integers, Struct, and Error as
data, plus Goblins' Set and Keyword. An Error value stays distinct from a broken promise on every surface. OCapN Null
is not implemented ([protocol limitations](boundaries.md#protocol-and-interop)).

Zig, C, and every binding accept a typed array of 64-bit integers as a list,
with the same wire meaning as individual integer values. A received array
arrives as a list. Capability-free far sends borrow their values through
encoding ([ADR-0064](decisions/adr/ADR-0064-borrowed-outbound-encoding.md),
[ADR-0064](decisions/adr/ADR-0064-borrowed-outbound-encoding.md)).
Served replies carrying no capability stay borrowed until the engine copies
them for retention ([ADR-0063](decisions/adr/ADR-0063-frame-owned-argument-views.md)).

## Codecs

| Codec       | Use |
| ----------- | --- |
| Syrup       | The interoperable OCapN wire format. Its fixtures are cross-checked against upstream Syrup encoders. |
| Cap'n Proto | glowcap-to-glowcap, with checked golden frames. Goblins speaks Syrup. |

The OCapN 1.0 profile uses Syrup. Two glowcap peers can offer Cap'n Proto or `"glowcap-next"` in their hellos and
settle on it ([ADR-0001](decisions/adr/ADR-0001-codec-profiles-and-negotiation.md)). A peer that makes no offer gets
1.0 over Syrup, so Goblins traffic is unchanged. Every binding offers `glowcap` and `interop` Host profiles. The
`rust-dogfood`, `deno-dogfood`, `python-dogfood`, and `racket-dogfood` checks run each binding over a live
Cap'n Proto socket. Zig applications can register another codec.

## Transports

| Transport     | Use |
| ------------- | --- |
| `iroh`        | Encrypted QUIC with discovery, relays, and a node ID that also serves as the OCapN designator. |
| `webrtc`      | An encrypted DataChannel reached through signaling, carrying a keyed OCapN session. The signaling service vouches for the peer's key. Every binding dials it with `webrtc.provider(signaling)` and listens with `webrtc.listen` (`listen-webrtc` in Racket). A browser dials with `connector` and listens with `listener` over its own peer connection. |
| `noise-tcp`   | TCP sealed with Noise_XK between the two peers. Completing the handshake proves the dialed key ([ADR-0041](decisions/adr/ADR-0041-sealed-byte-channels.md)). |
| `noise-relay` | A relay pipe sealed the same way. The relay only forwards ciphertext. Browsers and every binding that loads the C library can listen and dial. |
| `onion`       | The standard OCapN Tor netlayer. Tor proves the service to the dialer but reveals no caller identity to the listener. |
| `keyed-tcp`   | TCP with a key designator as the dial target. Cleartext and unauthenticated. |
| `keyed-relay` | Cleartext WebSocket to a relay, for a peer with no listening address. Trusted network and relay only. |
| `tcp`         | Cleartext testing path, with a host:port designator. |
| `inproc`      | An in-process connection for tests and deterministic local scenarios. |

[Community review](community-review.md) lists which transports meet live Goblins.

A relay locator can carry its own `rendezvous-relay` route. The Rust WebRTC stack accepts ICE server records, including
TURN credentials. The relay forwards bytes without parsing CapTP or holding a capability.

On Linux the TCP completion loop uses io_uring and falls back to epoll, and `net.tcpBackendStatus` reports which one
it chose. [Benchmarks](../bench/README.md) records the largest session run.

[Known limitations](boundaries.md#transports-and-peer-identity) compares their security and reachability.

## Resource models

[Loam](loam.md) is glowcap's storage layer: immutable collections, checksummed records with typed edges, and
transactions over SQLite, LMDB, or an in-memory engine.

- **Transactions** update several records atomically. A change made from stale data is refused.
- **Sleepy actors** keep their state in a record, load when a message arrives, and reply only after their change
  commits. Saved fields can hold references to other actors, attachments, and remote objects
  ([references](loam/references.md)).
- **Storage work** runs on your threads. `hosting.Worker` carries an attachment's reads and commits to the backend,
  and the C work handles are its slots ([API](loam/api.md#host-attachment-and-durable-actors)).
- **Durable names** let peers fetch an actor after a restart. Only the fetched actor wakes
  ([publications](loam/publications.md)).
- **Collection** removes unreachable records in bounded batches while the program runs
  ([collection](loam/collection.md)).
- **SQLite** is the default disk engine. It runs the same storage tests and crash tests from Zig, grows its capacity,
  and compacts in place ([SQLite operations](loam/sqlite.md)). It opens from C and Rust through `libglowcap_loam_sqlite`.
- **LMDB** returns failed disk reads as errors, grows its size limit within a budget, and compacts offline.
  When a commit's result is unknown, the store refuses other work until recovery finds out ([LMDB operations](loam/lmdb.md)).
- **The in-memory engine** opens from C and Rust through `libglowcap_loam_volatile`, with no path and a lock around
  each engine call. Its transactions admit multiple readers or one exclusive writer, preserving borrowed rows
  ([in-memory operations](loam/volatile.md)).
- **Storage failure tests** kill processes around commit and, on Linux, inject write and sync errors into both disk
  engines before checking a fresh process. They also fail reads and cut data files short. They do not cover power loss ([stability](stability.md)).
- **C and Rust** (`libglowcap_loam`, `libglowcap_loam_sqlite`, `libglowcap_loam_lmdb`, `libglowcap_loam_volatile`, and Rust's `loam` feature) create, share, edit, and
  restore a resource ([guide](loam/c-and-rust.md)). The [browser profile](loam/browser.md) does the same on
  IndexedDB.
- **`bench-loam`** measures LMDB workloads, including cold reads over a million
  resources, and the Tasks app on each disk engine, and a small version runs under `check`
  ([method](../bench/loam/README.md)). `profile-loam` attributes each marked
  phase under callgrind ([profiles](../bench/README.md)).

Rooms stores its managed session through Loam on SQLite and IndexedDB. The [session guide](rooms/session.md) owns that
contract.

### Managed access

Loam supplies separate use and control capabilities, scoped policy, durable issuance with exact recovery, and paged
management and observation. The [managed access coverage](loam/coverage.md) maps each surface to its tests.
[Known limitations](boundaries.md#managed-access) lists what remains.

## Actors and hosting

`actors.Vat` is a Goblins-style actor layer above the protocol engine. It supports local actors, eventual sends that
return vows, hosted objects, forwarding, attenuation, and revocation. Optional snapshots cover local actor state only
and never rewind a network session.

A Host owns one Vat and gives each session its own queue budget
([ADR-0014](decisions/adr/ADR-0014-actor-execution-and-lifetime.md)). A failed turn rolls back before failure listeners
run, and its sends are never published.

Every language binding hosts objects the same way. A browser peer can answer over the connection a call arrived on,
so a peer with no listening socket can still reply and take part in a handoff.

## Tools and applications

- `zig build` installs the `glowcap` command. It can listen, dial, call, fetch, run an interactive CapTP lab, serve
  an MCP interface, and join a Rooms session ([CLI guide](cli.md)).
- The rooms, tasks, and tools examples run one server with clients written in several bindings.
- The [Rooms application](../apps/rooms/) runs browser and terminal peers with durable sessions. Members hold rooms
  and direct messages with files over WebRTC, the Noise-sealed relay, iroh, and TCP. A session process started with
  `--dial-transports=webrtc` and a WebRTC member reach each other directly, signaling through a room they share.
  Directories peer, IRC works in both directions, and operator capabilities can be revoked.
  [What Rooms ships](../apps/rooms/shipped.md) has the details.
- ocapnviz opens a read-only trace sturdyref as a browser peer and shows replay and live events
  ([ADR-0040](decisions/adr/ADR-0040-trace-observation-authority.md)).
- The accountability example adds signed identity and an audit log above ordinary capabilities without changing
  CapTP.

The [examples](../examples/README.md) and [apps](../apps/README.md) pages list the programs.

## What checks it

[Stability](stability.md) says which checks recur, and what each one does not prove.
[Community review](community-review.md) is the outside-peer matrix.
