# Boundaries

This page names where the implemented surface ends — the edges of
[what ships today](shipped.md). Each boundary is deliberate and most are
pinned by a test or an ADR; none of them is a silent gap. The ordered plan
for moving these lines lives in the [ladder](ladder.md) and the
[roadmap](roadmap.md).

## Netlayer

A byte-stream netlayer ships in `net_adapter`. The active codec's own decoder
finds frame boundaries, so there is one parser (ADR-0029). `Connection` folds
that parser over `std.Io.Reader` and `std.Io.Writer`, and `net_adapter.tcp` is
the cleartext resident named `tcp` so it can address a Goblins netlayer. It
proves a real-socket handshake-to-open and bootstrap-fetch round-trip, plus the
same handshake, fetch, and call against a live Goblins vat (ADR-0035). The C
ABI re-exposes the socket path as blocking endpoint handles with a `last_error`
boundary (ADR-0030).

Read buffers size the steady state, not the largest admissible frame. A frame
that outgrows the read buffer assembles once in a bounded owned spill and is
freed when it drains, so per-connection memory does not scale with
`max_frame_bytes` (ADR-0041). The completion loop bounds the outbound side
too: when pending reply bytes cross a high-water mark, that connection stops
arming reads until the partner drains them (ADR-0042). The encrypted iroh
resident serves the blocking `ConnectedVat` path only; a completion-loop
integration for QUIC streams is now designed but not built — the event-driven
sidecar bridge of ADR-0057, which is what serving iroh at pancake's
~500k-connection scale signs up for — and TLS over TCP is not implemented
(ADR-0055). The blocking pump stays a single fiber by contract: it
serves cooperative request/response, and a partner that streams without
draining rides the completion loop instead (ADR-0053).

The TCP channel is cleartext, but it is no longer the only channel: an
encrypted iroh QUIC transport exists behind the same netlayer contract
(ADR-0055), carried by a Rust sidecar staticlib so `libpancake` stays pure
Zig, and `zig build iroh-interop` proves it live, pancake to pancake — keyed
handshake, bootstrap fetch, and deliver/resolve over real iroh endpoints. That
gate now also proves the QUIC/iroh cluster's three capstones: **dial-by-id
discovery** (the netlayer takes a configurable, no-default `Reachability`, and
the gate dials by node id alone through an address book — no direct-address
hints), **key unification** (one Ed25519 key per peer is at once the iroh node
id, the OCapN locator designator, and the session signing key, verified on both
handshake halves), and **durable identity** (a sturdyref of node id plus
swiss-number outlives an endpoint restart). `ocapn://<nodeid>.iroh` URI dialing
ships in all four bindings, each carrying the explicit reachability.

Three boundaries remain on the cluster, and each is named rather than implied:
serving iroh **at scale** is the event-driven completion-loop bridge of
ADR-0057 (designed, not built — today's concurrency is thread-per-connection);
**Goblins interop over iroh** is externally blocked (Goblins ships no iroh
netlayer); and a **native Zig QUIC** path stays rejected until iroh's protocols
stabilize and a production Zig QUIC stack exists (ADR-0055's flip condition).
The cross-language `demo-rooms-iroh` and the Deno iroh tests are flaky under
load — an FFI-teardown race and message loss under many concurrent dials — so
`iroh-interop` is the authoritative, deterministic iroh gate; the demo is
illustrative (see [the bridge plan](planning/iroh-completion-loop-bridge.md)).

## Sessions above the socket

Crossed hellos lives above the socket. A driver registry detects duplicate
peer sessions, and the engine projects the typed abort without learning about
sockets. The upstream OCapN suite exercises that path through
`zig build ocapn-conformance`. Against live Goblins, a pancake actor called by
a real Goblins client is proven both as a settled call and as a pipelined
enliven-and-call (ADR-0035). A full three-party handoff is also proven with
pancake as the recipient: it enlivens a Goblins introducer, receives a
Goblins-hosted cap by `desc:handoff-give`, dials the exporter directly,
presents a signed `desc:handoff-receive`, and calls the withdrawn cap. Those
bytes go straight to the exporter (`zig build goblins-handoff`).

Sturdyref enliven ships its initiator half (`engine.sturdyref`); its responder
half is the same inbound-`'fetch` serving path (`Peer.registerBootstrapCap`),
since an enliven is a `'fetch` against the local bootstrap exporter.
Distributed equality ships the in-memory substrate (`model.referencesEqual`,
`engine.SessionRegistry`). Container-type Pass Invariant Equality ships too:
`model.argumentsEqual` compares value trees through List, Set, Tagged, and
Struct shapes, with Set equality order-agnostic (a multiset) and Struct
equality order-independent over its keys, so each compares Equal whichever
codec's order carried it.

## The passable model and OCapN Null

The passable data model is complete except OCapN Null. `model.Argument` covers
bytes, string, symbol, keyword, integer, boolean, float64, void, list, set,
tagged, reference, error, handoff, and the OCapN Struct — the keyed-dictionary
passable, which both codecs carry (Syrup as a dictionary `{}`, Cap'n Proto as
a composite list of entry structs) with String-only keys, duplicate keys
refused at decode, and canonical key order on encode (ADR-0046). The Integer
is arbitrary-precision (ADR-0049): values in the i64 range ride the `integer`
fast path, and anything larger rides the `big_integer` arm as a sign plus
canonical decimal digits, carried by both codecs, compared bytewise, and
proven against a live Racket bignum in the `goblins-interop` echo. OCapN
Undefined is the `.void` arm: Goblins marshals the unspecified value as the
`<void>` record, and pancake speaks the same record. Null is held fail-closed
deliberately: Goblins has no Null marshalling and the upstream encoding is
unsettled, so inventing one would not interop. That is a fail-closed boundary,
not a silent gap.

On the pipelining side, all three projection ops are answered: receiving
`op:get`, `op:index`, or `op:untag` exports a promise at the new answer
position, and the engine resolves it to the Struct field, List element, or
unwrapped Tagged payload once the receiver settles
([ADR-0050](decisions/adr/ADR-0050-get-index-responder.md),
[ADR-0052](decisions/adr/ADR-0052-untag-responder.md)) — following
promise-shaped resolutions, and breaking on a missing field, an out-of-bounds
index, a mismatched tag, a wrong-shape value, or a broken receiver. Sending
one installs the outbound answer so the partner's resolve admits, and the live
`goblins-interop` gate pipelines an `op:index` against a settled answer and an
`op:get` against a still-pending one, both of which a real Goblins vat
resolves (Goblins has no `op:untag` marshaller yet, so untag's pressure is the
spec text, the Zig scenarios, and the upstream-encoder fixture).
`op:deliver-only` does not exist in the released v1.0 profile (a no-answer
`op:deliver` is the one-way send; `tell` uses it).

## The scalable I/O path

The scalable I/O path hosts and connects actors through driver APIs. The
completion loop takes per-connection hooks: `completion.Options.make_conn_ctx`,
`serve`, and `free_conn_ctx`. Those hooks bind an application context to each
connection, run it for every surfaced event, and free it at close.
`net_adapter` still remains actor-agnostic; it owns no actor layer.

`driver.LoopHost` packages those hooks behind a vat factory. It draws one
server identity key, hosts a fresh `Vat` per connection, and runs the keyed
handshake and per-event `serve` for each accepted partner. The application
publishes each connection's objects with `driver.publishNamed`. A loopback
test proves the whole round-trip on the io_uring backend: concurrent clients
complete the real keyed handshake through `driver.connectTcp`, fetch a
`LoopHost`-published actor, call it, and receive their replies. That proves
objects can answer through the same nine-verb surface without a thread per
connection.

`driver.LoopDialer` packages the outbound half. It draws one dialer identity
key, dials many TCP sessions through `completion.Loop.dialTcp`, binds a fresh
client vat to each peer, and runs application callbacks when each keyed
session opens. `dialTcp` returns before the connect resolves, so the dialer's
`on_close` callback is where a connection's end is observed — including a
refused dial, which reports there with `opened == false`. The returned `Slot`
is recycled and only names its connection until that close. A loopback test
pairs it with `driver.acceptTcp`: concurrent dialed clients fetch a hosted
actor, call it, and receive every reply on the completion loop.

The loop is also tested under churn. Hundreds of connection lifecycles recycle
through a small slot pool, and abrupt mid-handshake drops exercise the
teardown path. Read buffers come from a shared backend-owned pool (io_uring
provided buffers, ADR-0054), so an idle connection holds no read-buffer memory
and a frame split across reads rides the same bounded spill as an oversize
one.

Bootstrap capabilities are process-lifetime, not durable. If a host restarts,
a saved sturdyref re-enlivens against an empty registry until the app
re-registers the object.

Per-connection memory is the gated core state: the loop's read buffers are a
shared pool (256 buffers of 16 KiB by default, tunable via
`Options.read_buffers`), not a per-connection cost. The core's part of that
budget is gated, not just measured: `engine.Peer` carries a compile-time
ceiling on its struct size, a test holds a warmed session's core state under
2 KiB per connection, and `zig build bench-peer-scaling` reports the live
numbers ([ADR-0045](decisions/adr/ADR-0045-per-session-footprint-budget.md)).
The session-count arithmetic those budgets serve lives in the
[ladder](ladder.md).

## Codecs

The Cap'n Proto codec ([`src/ocapn/codec/capnp/`](../src/ocapn/codec/capnp/),
[ADR-0026](decisions/adr/ADR-0026-hand-rolled-capnp-codec.md)) is
engine-integrated and selectable on a live session: a peer pair negotiates it
(`engine.pairing.pairedWithCodec`), and the handshake plus all subsequent
traffic ride that codec through the codec-dispatch boundary (`session.codec`).
The same choice is reachable over the C ABI — `pancake_peer_new_negotiated`
constructs the peer and the tcp endpoints frame with the matching
`PANCAKE_CODEC_*` value — and every binding spells it in its own idiom. The
session state machine is codec-neutral, so the Goblins-v1.0 resolver-callback
translation is codec-blind. Cross-codec semantic parity is proven: the
deliver/resolve and bootstrap-fetch conformance scenarios produce identical
*observable* traces on Syrup and Cap'n Proto: the state machine is
codec-neutral, so the behavior does not depend on which codec carried it (the
two wire encodings differ; the observable trace does not). Authenticated
`op:start-session` verification uses the profile-level canonical
`<my-location …>` signing input, so Cap'n Proto sessions do not get a weaker
handshake path. The two codecs trade off differently: Cap'n Proto's
frames are larger on the wire but lay every field at a fixed offset, while
Syrup is more compact — a real consideration where per-connection density
matters. `zig build bench-codec` reports the current encode/decode ns/op and
MB/s for both rather than freezing a ratio here.

## The unbuilt driver

The second framework-shaped driver, `griddle` — a deterministic network
simulator and fuzzer — is not implemented. The [vision](vision.md) names what
it will be; nothing in the tree pretends it runs today.
