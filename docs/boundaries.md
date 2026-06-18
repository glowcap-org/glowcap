# Boundaries

This page names where the implemented surface ends — the edges of
[what ships today](shipped.md). Each boundary is deliberate and most are pinned
by a test or an ADR; none of them is a silent gap. The ordered plan for moving
these lines lives in the [ladder](ladder.md) and the [roadmap](roadmap.md).

## Netlayer

A byte-stream netlayer ships in `net`. The active codec's own decoder finds
frame boundaries, so there is one parser (ADR-0029). `Connection` folds that
parser over `std.Io.Reader` and `std.Io.Writer`, and `net.tcp` is the cleartext
resident named `tcp` so it can address a Goblins netlayer. It proves a
real-socket handshake-to-open and bootstrap-fetch round-trip, plus the same
handshake, fetch, and call against a live Goblins vat (ADR-0035). The C ABI
re-exposes the socket path as blocking endpoint handles with a `last_error`
boundary (ADR-0030).

Read buffers size the steady state, not the largest admissible frame. A frame
that outgrows the read buffer assembles once in a bounded owned spill and is
freed when it drains, so per-connection memory does not scale with
`max_frame_bytes` (ADR-0041). The completion loop bounds the outbound side too:
when pending reply bytes cross a high-water mark, that connection stops arming
reads until the partner drains them (ADR-0042). The encrypted iroh resident is
event-driven by construction (ADR-0057): `iroh.LoopHost` serves many QUIC
connections from one thread over the sidecar's readiness fd and non-blocking
frame I/O — its one I/O model, no blocking frame path beside it — proven by
`zig build iroh-loop` and measured at ~1.1 GiB of core state for 500k
connections (`bench-peer-scaling`'s `served` row). TLS over TCP is not
implemented (ADR-0055). The blocking pump stays a single fiber by contract: it
serves cooperative request/response, and a partner that streams without draining
rides the completion loop instead (ADR-0053).

pancake has two channels. TCP is cleartext; iroh QUIC is the encrypted one,
behind the same netlayer contract (ADR-0055), carried by a Rust sidecar
staticlib so the pure-Zig archives stay pure Zig. `zig build iroh-interop`
proves it live, pancake to pancake — keyed handshake, bootstrap fetch, and
deliver/resolve over real iroh endpoints — and proves the QUIC/iroh cluster's
three capstones: **dial-by-id discovery** (the netlayer takes a configurable,
no-default `Reachability`, and the gate dials by node id alone through an
address book — no direct-address hints), **key unification** (one Ed25519 key
per peer is at once the iroh node id, the OCapN locator designator, and the
session signing key, verified on both handshake halves), and **durable
identity** (a sturdyref of node id plus swiss-number outlives an endpoint
restart). `ocapn://<nodeid>.iroh` URI dialing ships in all four bindings, each
carrying the explicit reachability.

Dial-by-id reaches across the public internet, not just in-process: the opt-in
`zig build iroh-reachability` step dials by node id alone — two peers in the
`discovery` posture reach each other through n0's relays and DNS/pkarr with no
direct-address hints. It is opt-in, never part of `check` or the deterministic
`iroh-interop`, because publish-propagation timing makes it unsuitable as a
hermetic gate. One residual seam stays named: the proof runs two endpoints on
one host, so it exercises real discovery and real relay reach but not
hole-punching between two _distinct_ NATs; that last seam is verified by running
the step's two halves on separate networks, which the single-process gate cannot
do for you.

iroh serves at scale, in Zig and in every binding. The event-driven completion
loop of ADR-0057 is the netlayer's one I/O model (`iroh.LoopHost`, gated by
`zig build iroh-loop`, measured by `bench-peer-scaling`), so many connections
ride one loop thread rather than a thread apiece, and the public iroh netlayer C
ABI is loop-only: a single readiness fd (`pancake_iroh_netlayer_readiness_fd`)
the host parks on with its own poller, plus a non-blocking
`pancake_iroh_netlayer_drain_ready` and the `try_accept` / `try_connect` /
`conn_try_read` / `conn_try_write` surface. Every binding parks on that fd
natively, each in its own idiom: Deno's `IrohLoop` (a `node:net` socket on a
dup'd fd), Python's `_IrohLoop` (asyncio `add_reader`), Rust's `AsyncFd` task,
and Racket's `unsafe-file-descriptor->semaphore` park — no dedicated polling
thread, no busy-poll. Each is proven by a per-binding many-connection gate:
`bindings-iroh-loop` runs `python-iroh-loop`, `rust-iroh-loop`, and
`racket-iroh-loop` together, the binding siblings of `iroh-loop`. What remains
on scale is a live 500k-connection socket run, which still wants a load harness
(`bench-peer-scaling` Phase 2). Two boundaries remain on the cluster: **Goblins
interop over iroh** is externally blocked (Goblins ships no iroh netlayer); and
a **native Zig QUIC** path stays rejected until iroh's protocols stabilize and a
production Zig QUIC stack exists (ADR-0055's flip condition). The cross-language
`demo-rooms-iroh` and the Deno iroh tests are flaky under load — an FFI-teardown
race and message loss under many concurrent dials — so `iroh-interop` is the
authoritative, deterministic iroh gate; the demo is illustrative (see
[the bridge plan](planning/iroh-completion-loop-bridge.md)).

## Sessions above the socket

Crossed hellos lives above the socket. A driver registry detects duplicate peer
sessions, and the engine projects the typed abort without learning about
sockets. The upstream OCapN suite exercises that path through
`zig build ocapn-conformance`. Against live Goblins, a pancake actor called by a
real Goblins client is proven both as a settled call and as a pipelined
enliven-and-call (ADR-0035). A full three-party handoff is also proven with
pancake as the recipient: it enlivens a Goblins introducer, receives a
Goblins-hosted cap by `desc:handoff-give`, dials the exporter directly, presents
a signed `desc:handoff-receive`, and calls the withdrawn cap. Those bytes go
straight to the exporter (`zig build goblins-handoff`). Each binding proves the
same recipient-side redemption transparently through its own
`connect`/`fetch`/`send` surface — a binding-internal machine router redeems the
give and routes later sends to the exporter, the give and the second connection
never surfacing to application code (the `deno-goblins-handoff`,
`python-goblins-handoff`, `rust-goblins-handoff`, and `racket-goblins-handoff`
build steps).

The gifter half is now transparent too, across every binding: returning a `Ref`
whose home is a different connection deposits the gift and answers with a signed
`desc:handoff-give`, no choreography in application code. This rides one
identity and one gift registry per node — a node's accept, dial, and redeem
connections share a `Machine`, so a gift deposited on one connection is
withdrawable on another and a pancake node serves direct redeems as the exporter
(engine swiss re-resolution). It is proven all-pancake over loopback TCP
(`zig build deno-gifter-gate`, the broker out of the path), against a live
Goblins recipient and exporter per binding (`zig build deno-goblins-gift`,
`zig build python-goblins-gift`, `zig build rust-goblins-gift`, and
`zig build racket-goblins-gift`), and as the rooms app's
direct-message-by-introduction (`zig build demo-rooms-dm`).
The C ABI gifter primitives and shared-registry surface are language-neutral, and
each binding carries foreign-home detection in its own idiom (Deno/Python stamp
the ref's `home`, Rust/Racket key it by ref identity). Cross-process redeem
over iroh awaits the exporter's direct-address hints in the advertised session
locator (`iroh-mesh` reaches the exporter by node id alone via a shared
in-process discovery book), so the rooms DM demo runs over TCP for now.

The same three-party handoff now runs all-pancake **over iroh** — the mesh:
`zig build iroh-mesh` stands up three iroh endpoints where A introduces B to C,
and B reaches C **by the gifted node id**, withdraws the gifted capability
through C's own bootstrap (C's engine verifying both certificates), and calls
it. B's one Ed25519 key is at once its node id, its keyed-session key, and the
`recipient-key` the gift names, so the recipient A introduced and the endpoint B
dialed C from are provably the same key. This is the payoff of dial-by-id
reachability and key unification combined: a set of iroh connections becomes a
capability mesh, with no new protocol below the handoff substrate.

Sturdyref enliven ships its initiator half (`engine.sturdyref`); its responder
half is the same inbound-`'fetch` serving path (`Peer.registerBootstrapCap`),
since an enliven is a `'fetch` against the local bootstrap exporter. Distributed
equality ships the in-memory substrate (`model.referencesEqual`,
`engine.SessionRegistry`). Container-type Pass Invariant Equality ships too:
`model.argumentsEqual` compares value trees through List, Set, Tagged, and
Struct shapes, with Set equality order-agnostic (a multiset) and Struct equality
order-independent over its keys, so each compares Equal whichever codec's order
carried it.

## The passable model and OCapN Null

The passable data model is complete except OCapN Null. `model.Argument` covers
bytes, string, symbol, keyword, integer, boolean, float64, void, list, set,
tagged, reference, error, handoff, and the OCapN Struct — the keyed-dictionary
passable, which both codecs carry (Syrup as a dictionary `{}`, Cap'n Proto as a
composite list of entry structs) with String-only keys, duplicate keys refused
at decode, and canonical key order on encode (ADR-0046). The Integer is
arbitrary-precision (ADR-0049): values in the i64 range ride the `integer` fast
path, and anything larger rides the `big_integer` arm as a sign plus canonical
decimal digits, carried by both codecs, compared bytewise, and proven against a
live Racket bignum in the `goblins-interop` echo. OCapN Undefined is the `.void`
arm: Goblins marshals the unspecified value as the `<void>` record, and pancake
speaks the same record. Null is held fail-closed deliberately: Goblins has no
Null marshalling and the upstream encoding is unsettled, so inventing one would
not interop. That is a fail-closed boundary, not a silent gap.

On the pipelining side, all three projection ops are answered: receiving
`op:get`, `op:index`, or `op:untag` exports a promise at the new answer
position, and the engine resolves it to the Struct field, List element, or
unwrapped Tagged payload once the receiver settles
([ADR-0050](decisions/adr/ADR-0050-get-index-responder.md),
[ADR-0052](decisions/adr/ADR-0052-untag-responder.md)) — following
promise-shaped resolutions, and breaking on a missing field, an out-of-bounds
index, a mismatched tag, a wrong-shape value, or a broken receiver. Sending one
installs the outbound answer so the partner's resolve admits, and the live
`goblins-interop` gate pipelines an `op:index` against a settled answer and an
`op:get` against a still-pending one, both of which a real Goblins vat resolves
(Goblins has no `op:untag` marshaller yet, so untag's pressure is the spec text,
the Zig scenarios, and the upstream-encoder fixture). `op:deliver-only` does not
exist in the released v1.0 profile (a no-answer `op:deliver` is the one-way
send; `tell` uses it).

## The scalable I/O path

The scalable I/O path hosts and connects actors through driver APIs. The
completion loop takes per-connection hooks: `completion.Options.make_conn_ctx`,
`serve`, and `free_conn_ctx`. Those hooks bind an application context to each
connection, run it for every surfaced event, and free it at close. `net` still
remains actor-agnostic; it owns no actor layer.

`driver.LoopHost` packages those hooks behind a vat factory. It draws one server
identity key, hosts a fresh `Vat` per connection, and runs the keyed handshake
and per-event `serve` for each accepted partner. The application publishes each
connection's objects with `driver.publishNamed`. A loopback test proves the
whole round-trip on the io_uring backend: concurrent clients complete the real
keyed handshake through `driver.connectTcp`, fetch a `LoopHost`-published actor,
call it, and receive their replies. That proves objects can answer through the
same nine-verb surface without a thread per connection.

`driver.LoopDialer` packages the outbound half. It draws one dialer identity
key, dials many TCP sessions through `completion.Loop.dialTcp`, binds a fresh
client vat to each peer, and runs application callbacks when each keyed session
opens. `dialTcp` returns before the connect resolves, so the dialer's `on_close`
callback is where a connection's end is observed — including a refused dial,
which reports there with `opened == false`. The returned `Slot` is recycled and
only names its connection until that close. A loopback test pairs it with
`driver.acceptTcp`: concurrent dialed clients fetch a hosted actor, call it, and
receive every reply on the completion loop.

The loop is also tested under churn. Hundreds of connection lifecycles recycle
through a small slot pool, and abrupt mid-handshake drops exercise the teardown
path. Read buffers come from a shared backend-owned pool (io_uring provided
buffers, ADR-0054), so an idle connection holds no read-buffer memory and a
frame split across reads rides the same bounded spill as an oversize one.

Bootstrap capabilities are process-lifetime, not durable. If a host restarts, a
saved sturdyref re-enlivens against an empty registry until the app re-registers
the object.

Per-connection memory is the gated core state: the loop's read buffers are a
shared pool (256 buffers of 16 KiB by default, tunable via
`Options.read_buffers`), not a per-connection cost. The core's part of that
budget is gated, not just measured: `engine.Peer` carries a compile-time ceiling
on its struct size, a test holds a warmed session's core state under 2 KiB per
connection, and `zig build bench-peer-scaling` reports the live numbers
([ADR-0045](decisions/adr/ADR-0045-per-session-footprint-budget.md)). The
session-count arithmetic those budgets serve lives in the [ladder](ladder.md).

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
_observable_ traces on Syrup and Cap'n Proto: the state machine is
codec-neutral, so the behavior does not depend on which codec carried it (the
two wire encodings differ; the observable trace does not). Authenticated
`op:start-session` verification uses the profile-level canonical
`<my-location …>` signing input, so Cap'n Proto sessions do not get a weaker
handshake path. The two codecs trade off differently: Cap'n Proto's frames are
larger on the wire but lay every field at a fixed offset, while Syrup is more
compact — a real consideration where per-connection density matters.
`zig build bench-codec` reports the current encode/decode ns/op and MB/s for
both rather than freezing a ratio here.

## Reference lifecycle and ocap patterns

The engine sends and accounts the wire-delta GC messages: an outbound
`op:gc-exports` or `op:gc-answers` decrements the matching table rows, and the
inbound side balances them (`session.retainSentExports`,
`applyGcExportDecrement`). Every binding now drives those messages from a dropped
handle behind an opt-in, off by default (ADR-0063): a connection put into GC mode
(`with_gc` / `withGc` / `with-gc!`) registers a language finalizer on each far
reference returned by `fetch`, so when the collector reclaims the handle the
finalizer parks one `op:gc-exports` delta of 1 that the connection's own loop
drains to the wire on its next operation. The scope is deliberately just `fetch`
results — the one seam uniform across all four bindings; near refs, promises,
sturdyrefs (the enliven dedup cache owns those), the bootstrap import, and
redeemed handoff tokens are out of scope. With GC off, the prior behavior holds:
imports keep their table rows until teardown. `test/engine/gc_churn_test.zig`
proves the session reclaims import rows flatly under churn.

Sturdyref enliven ships a one-call `enliven()` convenience in every binding,
over the `pancake_peer_prepare_enliven` / `pancake_peer_record_enlivenment` C
ABI seam (ADR-0012 dedup cache): one call parses the sturdyref, consults the
cache, and on a miss drives the bootstrap-fetch to settlement. A repeat enliven
of the same swiss-number on an open session short-circuits with no wire traffic.
It is proven against a live Goblins-published cap (`zig build goblins-interop`).
The ocap-pattern helpers — caretaker, attenuator, and revocation built above the
sans-io core — are not implemented; an application composes them from the
capability primitives today.

## The unbuilt driver

The second framework-shaped driver, `griddle` — a deterministic network
simulator and fuzzer — is not implemented. The [vision](vision.md) names what it
will be; nothing in the tree pretends it runs today.
