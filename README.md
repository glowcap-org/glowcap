# pancake

<img src="assets/pancake.png" alt="" align="right" width="140" />

[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)
[![zero-copy contract](https://img.shields.io/badge/zero--copy-contract-blue.svg)](docs/architecture.md)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)

> **pancake is a codec-neutral [CapTP](http://erights.org/elib/distrib/captp/) core for [OCapN](https://github.com/ocapn/ocapn).**
> **Syrup where OCapN requires it. Owned frames or borrowed views wherever frames cross a boundary.**
> **Because you can't have pancakes without syrup.**

## What Is This?

pancake is a Zig implementation of the object-capability networking core: two
programs hand each other unforgeable references to remote objects and call
methods across a session with the same authority discipline as local
references. No ambient authority, no string-typed permissions. If you hold the
reference, you can use it.

It targets OCapN, the open object-capability network protocol from
[Spritely Institute](https://spritely.institute/) and the OCapN community. You use
it as a library, and you manage its memory yourself. The whole point of the design
is that nothing important hides: where a copy happens, where something is
allocated, which wire format is in play, where crypto runs, where I/O and
scheduling live — all of it stays visible at the boundary that owns it.

The conformance authority is OCapN behavior — as defined by Spritely Goblins on
the wire and the OCapN test suite. The in-repo gate checks pancake's protocol
scenarios and pancake-authored Syrup byte vectors against that intent, and
`zig build goblins-interop` adds a live conversation with a real Spritely Goblins
vat as a sibling of the hermetic gate (it needs a Racket/Goblins runtime on
PATH). The authority also runs *against* pancake directly: `zig build
ocapn-conformance` points the upstream OCapN test suite at a pancake peer. The
gate runs the suite modules pancake targets — `op:start-session`, `op:abort`,
`op:deliver`, `op:listen`, `op:gc`, and third-party handoffs — and fails unless
each module reports OK, so a regression in any of them turns the gate red. The
valid keyed handshake opens, and a malformed handshake — an invalid location
signature or an unrecognized version — is refused with a typed `op:abort` (the
peer verifies the partner's signature against the claimed key, it does not trust
it). The package name is `pancake`.

## Vision

pancake is headed toward being the most performant and most canonical OCapN
implementation there is: an idiomatic Zig API, a C ABI any language binding can
wrap natively, pluggable netlayers and codecs (use pancake's or bring your own, in
Zig and every binding), and full bidirectional conversations between any pancake or
binding peer and a real Spritely Goblins peer. Two framework-shaped drivers ride
above the core. The actor layer — a Goblins-shaped `Vat` — is real in every
binding: a runnable cross-language chat application (`zig build rooms`) joins Zig,
Rust, Python, Racket, and Deno members to one capability-secure room at once, each
calling the others back through capabilities it was handed. The second driver,
`griddle`, a deterministic network simulator and fuzzer, is not implemented. The
full north star, and the line between what ships today and what is still a target,
lives in [`docs/vision.md`](docs/vision.md).

## On The Wire Today

Implemented Zig behavior includes:

- **Frames.** `Frame` has one visible owner, `FrameView` borrows bytes, and
  `FrameShape` carries explicit byte vs word-aligned frame metadata.
- **Model.** Codec-neutral CapTP model types exist independently of the wire
  encoding that carried them.
- **Syrup.** The Syrup codec encodes the current message model against
  pancake-authored Syrup byte vectors (cross-checked through the upstream Syrup
  encoders, not Goblins captures), decodes borrowed views for the supported
  operation set, and materializes owned messages for engine-surfaced operations
  including start-session and handoff.
- **Session/engine.** Sessions own profile/features, lifecycle,
  import/export/answer/release authority, validate-then-apply, and feature
  gates. `Peer` remains caller-owned and drives outbound profile-aware encoding,
  V1.0 resolve-me-desc synthesis, borrowed inbound dispatch, owned queued
  inbound frames, outbound drains, and application-visible events for the
  supported decoded operations.
- **Third-party handoff.** Give and receive work end to end. The Syrup codec
  round-trips the handoff fixtures, the session owns a gift table with
  deposit/withdraw bookkeeping, signed-give consistency, and handoff-count replay
  rejection, and `engine.cross_peer` routes the flow from gifter to exporter to
  recipient across peers, with signature verification injected at the boundary.
  The session learns its partner's session key from the handshake, so the exporter
  records the depositing gifter's real key with the gift and a withdrawal is
  authorized under real Ed25519 by routing each certificate to its key — the give
  to the learned gifter key, the receive to the recipient key the give names — and
  a give signed by any other key is refused (ADR-0009). The gifter side ships its
  signing primitives too. `engine.handoff_gifter.buildSignedGive` builds the signed
  `desc:handoff-give` a gifter returns once it has deposited the gift, embedding the
  exporter's verbatim `op:start-session` location so a peer matching the give's
  location to the session matches it byte for byte. The session also learns the
  partner's location designator from the handshake (`Session.partnerDesignator`) so
  a host can route across both the gifter-to-exporter and gifter-to-recipient
  sessions, while the I/O-bound enliven, fetch, and deposit choreography stays in
  the host adapter.
- **Promise pipelining.** Sessions own the inbound-answer table, listeners, and
  stored resolutions; `engine.pipeline` carries the pure transforms. A pipelined
  `op:deliver` against an unresolved answer queues and drains to the resolution
  (local delivery, requeue, or far-forward) when `op:resolve` settles, and a
  multi-hop call path decomposes at the sender into chained single-hop frames so
  every `desc:answer` on the Syrup wire stays flat.
- **Relayed-resolution forwarding.** An `op:listen` on a handoff-imported promise
  installs against the third-party-hosted import; when the introducing session
  forwards the host's resolution, `engine.cross_peer.drainRelayedResolutions`
  fires the listeners and stores the resolution so a late listener fires
  immediately (ADR-0009).
- **Bootstrap fetch (initiator).** `engine.fetch` builds the canonical
  bootstrap-fetch `op:deliver` and matches the partner's settlement — an
  `op:resolve` or a resolver-callback `op:deliver` — into an owned outcome.
  Driving the wire loop between the two is an adapter concern; the core ships the
  no-I/O halves.
- **Bootstrap fetch (responder).** `Peer.registerBootstrapCap(swissnum)` exposes
  a local capability behind a swiss-number; an inbound `'fetch` to the bootstrap
  export is then recognized and answered automatically by the dispatcher
  (`engine.bootstrap` synthesizes the `Resolve`; the V1.0 path renders it as a
  resolver-callback), with `break "unknown swissnum"` for an unregistered
  swissnum (ADR-0006 responder half).
- **Sturdyref enliven (initiator).** `engine.sturdyref` turns a persistent
  `(peer, swissnum)` sturdyref into a live `Reference` over the existing
  bootstrap-fetch: a feature-negotiated + open precondition gate, a session dedup
  cache that maps a swissnum to its `(import_id, kind)` (the kind is preserved) and
  short-circuits a repeat enliven with no wire traffic, and an in-flight marker that collapses a
  concurrent enliven onto the outstanding answer. The wire loop is adapter-driven,
  exactly like `engine.fetch`.
- **Distributed equality.** `model.referencesEqual` is the codec-neutral
  structural-equality predicate — the in-memory evidence for OCapN Pass Invariant
  Equality (ADR-0012): two references that name the same target compare equal
  regardless of which codec or profile carried them. `engine.SessionRegistry`
  enforces one session per `PeerId` (`PeerAlreadyOpen` on a duplicate open), so
  cross-session equality reduces to same-session equality on `(import_id, kind)`;
  the sturdyref dedup cache supplies the sturdyref-vs-handoff collapse.
- **Handshake feature negotiation.** `model.FeatureSet.intersect` is the
  per-feature AND, and `engine.negotiation.negotiate` is the pure, symmetric
  pick of the most-preferred shared codec plus the intersected feature set over
  two `Offer`s. `op:start-session` carries no feature operand (pancake does not
  extend OCapN's wire shapes), so both ends compute the same answer from the same
  offers; `pairing.pairedWithOffers` constructs both peers with the negotiated
  set, so neither exercises a capability the other withheld.
- **Fail-loud aborts.** A rejected inbound frame — a codec-malformed frame or a
  session state-machine refusal — projects through `engine.abort_projection` to
  a typed outbound `op:abort` (and a session close where warranted) before the
  error surfaces, instead of bubbling a bare host error and leaving the partner
  hanging. Both inbound entry points share the projection.
- **Resource caps.** `SessionLimits` bounds the partner-driven tables — imports,
  the seen-handoff-count replay set, and deposited gifts — alongside the existing
  pipelining caps; each overflow is a loud `*CapExceeded` error that projects to
  a `ResourceExhausted` abort (ADR-0025), never a silent drop.
- **C ABI and adapters.** The C ABI frame vocabulary is fixed-width and
  release-explicit. Borrowed frames dispatch synchronously; managed frames
  transfer ownership without copying; events return the originating frame in the
  negotiated codec with explicit release and no re-encode. `std.Io` appears at
  the adapter boundary, not in the core. Allocation policy is a `PancakeContext`:
  the `*_in` constructors allocate a whole handle family — peers, netlayers, and
  every managed frame and buffer they own — through a context you supply (the
  library allocator by default, or host `alloc`/`free` callbacks), freed back
  through the same context. The keyed `op:start-session` handshake is on the C
  ABI too: `pancake_peer_new_negotiating` opens a handshake-ready peer, and
  `pancake_peer_start_session_keyed` signs the canonical location bytes from a
  32-byte seed and queues the start-session, so a binding reaches an open keyed
  session (with a real Goblins vat) without re-implementing the crypto. The
  library never generates entropy; the seed is the one place key material crosses
  the boundary.
- **Protocol oracle bridge.** `zig build oracle-check` enumerates shipped
  message arms, checks pancake-authored Syrup fixture parity across the upstream
  Syrup encoders, and runs engine scenarios
  including the multi-peer third-party handoff. `conformance` also drives a
  deliver-then-resolve round-trip, a handshake that auto-serves a bootstrap fetch
  (the ADR-0006 responder half), and a cross-mode parity check that proves the
  borrowed (`recvBorrowed`) and owned (`feedInbound` + `step`) inbound entry
  points run one dispatcher (byte-identical observable output).
- **Actors.** `actors.Vat` is a Goblins-shaped layer above the engine. You spawn
  local objects, call them synchronously with `$`, and eventual-send to them with
  `<-` to get a `Promise` back; an object "becomes" by mutating its own state. A
  peer-bound vat makes that same `<-` location-transparent — a local target runs a
  turn, a far target leaves as an `op:deliver` over the peer — and `publish` /
  `serve` host a local object at an export, so a partner's inbound deliver runs the
  object's turn and resolves the answer. The layer is sync and owns no I/O
  (ADR-0036). Every binding mirrors the same local|far seam in
  its own idiom — the Racket one Goblins-faithful, the Rust, Python, and Deno ones
  native to each language — and each proves a far-send round-trip in its dogfood
  (ADR-0039).
- **One application surface, every binding.** Each binding exposes the same small
  surface — `connect`/`listen`, `fetch`/`publish`, `spawn`, `send`, `tell`,
  `serve`, `close` — in its own idiom: Deno and Python return native
  promises/coroutines, Rust returns an `impl Future` from a `!Send` `Connection`,
  Racket keeps the Goblins verbs (`spawn`, `$`, `<-`, `<-np`, `on`). `send` awaits
  a reply; `tell` is the fire-and-forget eventual-send. `connect` and `listen`
  complete the keyed `op:start-session` handshake before they return, so the
  session is an established OCapN session — the same handshake a real Goblins peer
  requires, not a pre-opened shortcut. Each side verifies the partner's location
  signature against the claimed key and refuses an unauthenticated handshake with
  a typed `op:abort` — the secure default a negotiating peer carries, checked at
  the engine boundary while the session core still runs no crypto. The session key
  is a per-connection seed the binding draws at the I/O boundary; the sans-io core
  never generates entropy.
  A client `connect`s, `fetch`es a
  server's capability by name (a swiss-number, not a slot number), `spawn`s a local
  actor, and hands the server a reference to it; a returned `Ref` auto-marshals as
  a capability argument. No export-position numbers, no manual flush, no
  hand-rolled serve loop in application code. In native Zig the same surface is the
  `driver.ConnectedVat` (`driver.connectTcp`), a transport-neutral driver above
  both `actors` and `net_adapter` that keeps allocation, ownership, and I/O visible
  (one `step()` per pump cycle) — the Zig promise kept at the application layer.
  When a pump cycle finds the connection closed, the driver breaks every `send`
  still waiting on a reply, so an outstanding call settles broken instead of
  hanging on a reply that can never arrive. The Deno, Python, and Rust
  `Connection`s break their pending sends the same way when their serve loop ends.
  The raw `Peer`/`Vat`/`AsyncConnection` remain reachable (`conn.peer`) for
  handoff, pipelining, and session control.
- **Three real cross-language applications.** All three run a server and one
  client per language over one OCapN wire, and assert the result. Every
  connection is a keyed-handshake-established session — the client `connect` and
  the server's accept both complete the `op:start-session` exchange — so the
  wire is a real OCapN session, not a pre-opened one. That the same `connect` /
  `fetch` / `send` surface is OCapN-conformant is proven against a real Goblins
  vat, not just between pancake peers: `zig build deno-goblins-interop`,
  `python-goblins-interop`, `rust-goblins-interop`, and `racket-goblins-interop`
  each drive their binding's application surface through the keyed handshake,
  fetch, and call against live Goblins. `zig build rooms`
  is a chat room (real-time push through capability callbacks) joining Zig, Rust,
  Python, Racket, and Deno. `zig build tasks` is a shared task board (CRUD with
  promises and live updates) across the same five. `zig build tools` is an
  AI-agent-harness showcase: a coordinator grants an agent attenuated and
  revocable capabilities to tools, and a Zig, Rust, Python, Racket, and Deno agent
  each proves delegation, attenuation, and revocation on the wire — coordinator
  and agent in different languages. Each needs only `deno` (rooms/tasks/tools also
  build a Zig client/agent); other-language participants join when their runtimes
  are present. All run as siblings of the hermetic `check`. See
  [`examples/apps/`](examples/apps/).
- **Accountability application on pancake.** `zig build accountability` runs the
  first real application on pancake's own runtime: KERI-anchored identity, a signed
  Episode per capability invocation, a Merkle transparency log, and a host that
  refuses to account for a caller it cannot attest — the refusal path that an
  encode/decode asymmetry in the Syrup codec had blocked (fixed: the `.error`
  argument arm is now exhaustive). Two native pancake peers complete an OCapN
  handshake over a real loopback TCP socket, and every invocation produces a
  verifiable Episode attributing the attested caller. The same Affordance is
  reachable from Deno and Python callers over the C ABI (`libpancake.so`): same
  application, three languages, each on a keyed-handshake-established OCapN
  session — the host completes the responder half and the foreign callers
  `connect` through the keyed `op:start-session` exchange, the same handshake the
  application surface and a live Goblins peer use. A three-party handoff test
  (`zig build accountability-three-party`) proves that after A introduces B to C,
  C attributes B (the true caller), not A. Identity, Episodes, and the
  transparency log stay entirely above pancake; the one core change was restoring
  encode/decode symmetry in the codec. See
  [`conformance/accountability-on-pancake/`](conformance/accountability-on-pancake/).
- **Pluggable codecs.** Codecs resolve through an open comptime registry keyed by a
  non-exhaustive `model.CodecId`. The built-ins are `syrup` and `capnp`; a Zig
  consumer adds their own by declaring `pub const pancake_codecs` in the root
  source file, and dispatch unrolls at comptime so the open set keeps the
  zero-indirection of the former closed switch (ADR-0026).
- **Pluggable transports.** The transport seam is a `*std.Io.Reader` /
  `*std.Io.Writer` pair. `net_adapter.pumpOver` drives a peer over any such pair,
  `net_adapter.tcp` is the built-in binding, and a non-stream transport drives the
  peer directly through `Peer.recvStreamPrefix` / `takeOutbound` — the same path a
  language binding uses over the C ABI. Bring-your-own netlayer is a tested
  contract, not a deferred abstraction (ADR-0030).
- **OCapN locator URIs.** `model.uri` parses and emits the out-of-band bootstrap
  form — `ocapn://<designator>.<transport>?hints` for a peer,
  `ocapn://<designator>.<transport>/s/<swiss-num>` for a sturdyref — against owned
  `model.PeerLocator` / `model.SturdyRef`. The transport is the suffix after the
  last `.`, hints are RFC 3986 query parameters, percent-encoding is `%XX`-only so
  a base64 designator round-trips byte-for-byte, and the conformance peer's own URI
  parses back to its parts. This is the format any netlayer address is shared in;
  it is a core codec today, not yet wired into the bindings' `connect`/`fetch`.
- **Live Goblins interop, both directions.** `zig build goblins-interop` proves a
  real Spritely Goblins v0.18.0 conversation each way. As a client, pancake spawns
  a Goblins vat, dials it over `net_adapter.tcp`, completes the keyed
  `op:start-session` handshake while verifying Goblins' own Ed25519 signature,
  bootstrap-fetches Goblins' echo capability, and calls it to a fulfilled
  resolution (ADR-0035). As a listener, pancake binds a TCP listener and publishes
  a vat actor behind a swiss-num; a real Goblins client dials in, enlivens the
  actor, and calls it, and the actor's turn resolves the answer Goblins reads back
  (ADR-0035). It needs `racket` plus the `goblins` collection on PATH, so it runs
  as a sibling of the hermetic `check`, not inside it. Every binding reaches the
  same live conversation over the C ABI: `zig build deno-goblins-interop`,
  `python-goblins-interop`, `rust-goblins-interop`, and `racket-goblins-interop`
  each drive their binding through the keyed handshake with a real Goblins vat,
  then bootstrap-fetch its echo cap and call it. The keyed exchange runs from
  every binding, not only from native Zig.
- **Architecture gate.** `zig build arch-check` walks `src/**/*.zig`, parses the
  `@import` edges, and enforces the layer dependency DAG (codec-neutral session,
  no-`std.Io`-in-core, codecs own no authority) — a new top-level module with no
  declared rule fails the gate loudly.
- **Meta scaffolding gate.** `zig build meta-check` verifies canonical `.agents`
  guidance, thin Cursor/Claude overlays, hook and Serena MCP wiring, ignored
  generated state, and documented build-step names.
- **Rust C ABI dogfood.** A Rust crate links `libpancake` through the C ABI and
  drives a peer smoke test through the public host boundary.

## Current Boundaries

A byte-stream netlayer ships (`net_adapter`): the active codec's own decoder
finds frame boundaries (one parser, ADR-0029), a `Connection` folds it over
`std.Io.Reader`/`Writer`, and `net_adapter.tcp` (cleartext, transport symbol
`tcp` so it can address a Goblins netlayer) proves a handshake-to-open +
bootstrap-fetch round-trip over a real socket, and the same handshake plus a
bootstrap fetch and a call to a fetched cap against a live Goblins vat (ADR-0035).
The C ABI re-exposes it as blocking endpoint handles with a `last_error` boundary
(ADR-0030). Still outside the shipped surface: production transports (TLS,
QUIC/iroh), full-duplex backpressure, crossed-hellos, and the small-buffer /
bounded-overflow read path — all deferred by name in ADR-0030. Against live
Goblins, a pancake actor called by a real Goblins client is proven both as a
settled call and as a pipelined enliven-and-call in one breath (ADR-0035), and a
full three-party handoff is proven with pancake as the recipient: it enlivens a
Goblins introducer, receives a Goblins-hosted cap by `desc:handoff-give`, dials
the exporter directly, presents a signed `desc:handoff-receive`, and calls the
withdrawn cap — the bytes going straight to the exporter (`zig build
goblins-handoff`). Crossed hellos is the remaining live follow-on scenario, not
yet proven.

Sturdyref enliven ships its initiator half (`engine.sturdyref`); its
responder half is the same inbound-`'fetch` serving path
(`Peer.registerBootstrapCap`), since an enliven is a `'fetch` against the local
bootstrap exporter. Distributed equality ships the in-memory substrate
(`model.referencesEqual`, `engine.SessionRegistry`). Container-type Pass
Invariant Equality ships too: `model.argumentsEqual` compares value trees through
List, Set, and Tagged shapes, with Set equality order-agnostic (a multiset) so a
set compares Equal whichever codec's element order carried it. Null, Dict,
Float32 fidelity, and bignum integers stay unmodeled.

The Cap'n Proto codec ([`src/codec/capnp/`](src/codec/capnp/), [ADR-0026](docs/decisions/adr/ADR-0026-hand-rolled-capnp-codec.md))
is engine-integrated and selectable on a live session: a peer pair negotiates it
(`engine.pairing.pairedWithCodec`), and the handshake plus all subsequent
traffic ride that codec through the codec-dispatch boundary (`session.codec`). The
session state machine is codec-neutral, so the Goblins-v1.0 resolver-callback
translation is codec-blind. Cross-codec semantic parity is proven: the
deliver/resolve and bootstrap-fetch conformance
scenarios produce identical *observable* traces on Syrup and Cap'n Proto: the
state machine is codec-neutral, so the behavior does not depend on which codec
carried it (the two wire encodings differ; the observable trace does not). The one Cap'n
Proto boundary that remains is the real-crypto handshake — the canonical
`<my-location …>` signing input is profile-defined (Syrup), so a Cap'n Proto
session uses the stub-key path.

## Design Posture

- Substrate first. The core is a library, not a framework. The framework-shaped
  layers — a Goblins-style actor framework, a network simulator — belong *above*
  the core as optional drivers, never inside it (see [`docs/vision.md`](docs/vision.md)).
- Protocol semantics are fixed, correct, and interoperable.
- Implementation overhead is aggressively minimized.
- The canonical core stays deterministic, sync, and no-I/O.
- Zig `std.Io` belongs in adapter/netlayer layers, not in the core or C ABI.
- C ABI surfaces stay C-shaped: opaque handles, fixed-width return codes,
  `ptr + len` frames, callbacks, and explicit release functions.
- Zero-copy is a contract: every copy is forbidden, intentional, or measured.
- Frame movement defaults to owned transfer or bounded borrow; copy helpers live
  in `test/support`, not in production modules.
- Public examples compile as part of the build; README usage must stay honest.

## Foundation Contract

Ownership APIs and inbound dispatch surfaces every protocol layer builds on:

- `Frame.initOwned` / `Frame.initExternal`: adopt storage without copying;
  alignment and release hooks stay explicit at the API boundary.
- `feedInbound(Frame)` and `recvBorrowed(FrameView)`: owned queued vs bounded
  borrowed inbound dispatch.
- Tests and benchmarks prove views do not allocate or copy and track frame/view
  overhead.

## Devcontainer

Open with _Dev Containers: Reopen in Container_, then:

```sh
bash .devcontainer/post-create.sh
zig build check
```

Toolchain pins: [`./.devcontainer/pins.sh`](.devcontainer/pins.sh). Boundaries and
environment notes: [`./.devcontainer/README.md`](.devcontainer/README.md).

## Quick Start

```sh
zig build
zig build check
zig build meta-check
zig build oracle-check
zig build rust-dogfood
zig build bindings
zig build examples
zig build rooms
zig build tasks
zig build tools
zig build test
zig build bench-frame-view
zig build bench-codec
```

`zig build` installs `libpancake.a`, `libpancake.so`, and `pancake.h` under
`zig-out/`.

`zig build check` is the Zig-hermetic correctness gate — the architecture gate,
meta scaffolding gate, tests, the example programs, the protocol/Syrup oracle
checks, and the frame/view + codec throughput benchmark smoke checks; a Zig
toolchain is all it needs. The
cross-language C ABI dogfood (`zig build rust-dogfood`, `zig build bindings`)
needs cargo/deno/python/racket on PATH, so it runs as a separate step alongside
`check`. `zig build arch-check` runs the layering gate on its own. `zig build
meta-check` runs the agent/docs scaffolding gate on its own. `zig build
bench-codec` reports codec encode/decode throughput,
steady-state dispatch ns/turn, and the sparse partner-position table cost.
`zig build oracle-check` runs the protocol manifest and pancake-authored Syrup
fixture checks directly.

## Examples

Runnable CapTP walkthroughs, narrated in each program's `//!` header and run
under `zig build examples` (and `zig build check`) — see
[`examples/README.md`](examples/README.md) for the index.

- [`examples/zig/01_call_a_remote_method.zig`](examples/zig/01_call_a_remote_method.zig)
  pairs two peers; one calls a method on the other and reads the answer back.
- [`examples/zig/02_look_up_by_name.zig`](examples/zig/02_look_up_by_name.zig)
  fetches a capability through the bootstrap object by swiss-number — the server
  side is just `registerBootstrapCap`, and the engine answers the `'fetch`.
- [`examples/zig/03_actor_far_send.zig`](examples/zig/03_actor_far_send.zig)
  publishes an actor, far-sends to it across a paired session, and settles the
  promise — the `actors.Vat` pattern every networked application builds on.

Every binding exposes one small application surface — `connect`, `listen`,
`fetch`, `publish`, `spawn`, `send`, `serve`, `close` — that reads the same in
each language. A client connects, fetches a server's capability by name, spawns a
local actor, and hands the server a reference to it; the server calls it back. No
export-position numbers, no manual flush, no hand-rolled receive loop. In Deno:

```typescript
import { connect } from "./bindings/deno/pancake.ts";

const conn = await connect("127.0.0.1", 9099);
conn.serve().catch((e) => console.error(e));
const board = await conn.fetch("board");          // a capability, by name
const id = await conn.send(board, "add", ["buy groceries"]); // call it, get a reply
```

Three full applications run across every binding, one per domain capability
networking is winning:

- [`examples/apps/rooms/`](examples/apps/rooms/) — real-time. A capability-secure
  chat room with a Deno server and one client per language (Zig, Rust, Python,
  Racket, Deno). `zig build rooms` joins all five to one room over TCP and asserts
  every member sees every message through capability callbacks.
- [`examples/apps/tasks/`](examples/apps/tasks/) — services / CRUD with live
  state. A shared task board, one client per language (Zig, Rust, Python, Racket,
  Deno). `zig build tasks`: add a task, list, mark it done, confirm — promises as
  request-response, structured data on the wire, live change notifications.
- [`examples/apps/tools/`](examples/apps/tools/) — AI agent harnesses. A
  coordinator hands an agent capabilities to tools, attenuated and revocable; a
  Zig, Rust, Python, Racket, and Deno agent each proves delegation, attenuation,
  and revocation over OCapN, with coordinator and agent in different languages.
  Least authority by construction — the model AI tooling fakes with API keys and
  allowlists.

Lower-level library mechanics:

- [`examples/zig/frame_view.zig`](examples/zig/frame_view.zig) consumes pancake
  as a Zig library and demonstrates owned `Frame` to borrowed `FrameView`.
- [`examples/c/frame_view.c`](examples/c/frame_view.c) consumes
  [`pancake.h`](include/pancake.h), links `libpancake`, and calls an exported C
  ABI symbol.

## Reference & Conformance

- [`conformance/`](conformance/) — external conformance pressure: the OCapN
  test suite (submodule), pancake's Spritely Goblins peer, a pancake peer the
  suite can be pointed at (`zig build ocapn-conformance`, which pancake passes
  for `op:start-session` keyed-handshake conformance), the accountability applications
  (on Goblins and on pancake) + their `.data/` corpora, and the KERI/episode
  oracles. `accountability-on-pancake` is the first real application
  on pancake's own runtime (run: `zig build accountability`; cross-seam:
  `deno run ... deno/demo.ts`). Initialize the upstream submodules with
  `bash conformance/bootstrap-submodules.sh`.
- [`bindings/`](bindings/) — per-language consumers of the `libpancake` C ABI
  (rust, deno, python, racket), each dogfooding the ABI. Run with
  `zig build bindings`.
- [`test/oracles/`](test/oracles/) — the canonical Syrup byte corpus (gated by
  `zig build oracle-check`) plus the Racket and Python upstream-Syrup generators
  that reproduce it.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) explains the memory, C ABI, and
  layer boundaries.
- [`docs/captp-examples/README.md`](docs/captp-examples/README.md) indexes the
  living CapTP diagrams.
- [`docs/planning/reference-rehoming.md`](docs/planning/reference-rehoming.md)
  is a historical snapshot for the re-homed reference material above.
- [`AGENTS.md`](AGENTS.md) is the agent entrypoint for invariants and
  scaffolding discipline.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) is the contributor entry point; this is a
  one-person project, so reviews are best-effort.
- [`SECURITY.md`](SECURITY.md) is the vulnerability-reporting policy and the
  protocol invariants a security report may cite.

## License

Licensed under [Apache-2.0](LICENSE-APACHE). Contributions are accepted under the same terms.

