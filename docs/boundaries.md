# Boundaries

This page names where the implemented surface ends, the edges of
[what ships today](shipped.md). Every boundary here is deliberate. Most are
pinned by a test or an ADR, and none is a silent gap. The plan for moving these
lines lives in the [ladder](ladder.md) and the [roadmap](roadmap.md).

## Netlayer

A byte-stream netlayer ships in `net`. The active codec's decoder finds frame
boundaries, so there is one parser (ADR-0029). `Connection` folds that parser
over `std.Io.Reader` and `std.Io.Writer`. `net.tcp` is the cleartext resident
named `tcp` so it can address a Goblins netlayer; it proves a real-socket
handshake-to-open and bootstrap-fetch round-trip, and the same handshake, fetch,
and call against a live Goblins vat (ADR-0035). The C ABI re-exposes the socket
path as blocking endpoint handles with a `last_error` boundary (ADR-0030).

TCP also has a restart-stable identity posture: `net.tcp_keyed`, the `keyed-tcp`
resident (ADR-0075). Its locator designator is the listener's Ed25519 public key
in canonical hex, the socket address rides the `direct-addresses` hint, and the
driver pins the handshake to the dialed key (`engine.Peer.expectPartnerKey`), so
a partner re-dials the same designator across a process restart with only the
hint updated and a key squatter is refused before the session opens. Be clear
about what that buys: the channel is still cleartext — anyone on the path reads
every frame — and because the start-session signature covers static location
bytes, an active middlebox can relay the genuine listener's signed hello and
then read or alter ordinary traffic. The pin authenticates the advertisement
and makes impersonating the key impossible for operations that need a fresh
signature under it (minting and redeeming handoff certificates); channel
confidentiality and integrity remain iroh's. The hinted keyed location is a
Syrup-session feature today, since the Cap'n Proto codec refuses non-empty
locator hints on encode. Binding-level keyed-tcp surfaces and a C ABI
`expect_partner_key` export are not implemented (ADR-0075 § Scope).

Read buffers size the steady state, not the largest admissible frame. A frame
that outgrows the read buffer assembles once in a bounded owned spill, freed when
it drains, so per-connection memory does not scale with `max_frame_bytes`
(ADR-0041). The completion loop bounds the outbound side: when pending reply
bytes cross a high-water mark, that connection stops arming reads until the
partner drains them (ADR-0042). The encrypted iroh resident offers two consumer shapes (ADR-0057): a blocking
sidecar path for single-connection `ConnectedVat` use, and `iroh.LoopHost`, which
serves many QUIC connections from one thread over the sidecar's readiness fd and
non-blocking frame I/O. `zig build iroh-loop` proves that multiplexing across
concurrent connections; it proves correctness, not memory. The loop-driven per-connection
cost is the `served` row of `bench-peer-scaling`, which extrapolates to roughly
1.1 GiB of core state for 500k connections, reported not gated. The gated budget
is the warmed session `test/engine/footprint_budget_test.zig` holds at or under
2 KiB. TLS over TCP is not implemented (ADR-0055). The blocking pump stays a
single fiber by contract: it serves cooperative request/response, and a partner
that streams without draining rides the completion loop instead (ADR-0053).

pancake has two channels. TCP is cleartext; iroh QUIC is encrypted, behind the
same netlayer contract (ADR-0055), carried by a Rust sidecar staticlib so the
pure-Zig archives stay pure Zig. `zig build iroh-interop` proves it live, pancake
to pancake: a keyed handshake, bootstrap fetch, and deliver/resolve over real
iroh endpoints. It also proves the iroh cluster's three capstones.
**Dial-by-id discovery**: the netlayer takes a configurable, no-default
`Reachability`, and the gate dials by node id alone through an address book, no
direct-address hints. **Key unification**: one Ed25519 key per peer is at once
the iroh node id, the OCapN locator designator, and the session signing key —
library-enforced on the native dial path, where `driver.connectVia` pins every
key-designator dial to the dialed key and the engine refuses any other key at
the handshake (ADR-0075); the byte-fed host tier does not pin iroh dials yet
(ADR-0075 § Scope). **Durable identity**: a sturdyref of node id
plus swiss-number outlives an endpoint restart. `ocapn://<nodeid>.iroh` URI
dialing ships in all four bindings, each carrying the explicit reachability.

Dial-by-id reaches across the public internet. The opt-in
`zig build iroh-reachability` step dials by node id alone: two peers in the
`discovery` posture reach each other through n0's relays and DNS/pkarr, no
direct-address hints. It stays out of `check` and the deterministic
`iroh-interop` because publish-propagation timing makes it unfit as a hermetic
gate. Each binding has the same live proof through its own `connect_iroh`
surface, via the opt-in `zig build bindings-iroh-reachability` gates
(`python-`/`rust-`/`racket-iroh-reachability`). These prove the `discovery`
posture (relays + DNS/pkarr).
The `discovery_no_relay` posture (DNS/pkarr, no relay fallback) is deliberately
ungated: reaching a no-relay node by id needs that node to own a publishable,
reachable direct address, which a NAT'd host or container lacks, so a gate for it
would be permanently red. The `connect_iroh` dialers still settle/retry under
`discovery_no_relay` by the same propagation principle; only the *live gate* is
infeasible without a publicly-addressable host. One seam stays named: the
discovery proof runs two endpoints on one host, exercising real discovery and
relay reach but not hole-punching between two _distinct_ NATs. Verifying that
means running the step's two halves on separate networks, which the
single-process gate cannot do.

iroh serves at scale, in Zig and in every binding. The event-driven completion
loop of ADR-0057 (`iroh.LoopHost`, gated by `zig build iroh-loop`, measured by
`bench-peer-scaling`) is the scale path: many connections ride one loop thread
rather than one apiece. The public iroh netlayer C ABI is that path alone —
loop-only: a single readiness fd (`pancake_iroh_netlayer_readiness_fd`) the host
parks on with its own poller, a non-blocking `pancake_iroh_netlayer_drain_ready`,
and the `try_accept` / `try_connect` / `conn_try_read` / `conn_try_write`
surface. Every binding parks on that fd in its own idiom, with no dedicated
polling thread and no busy-poll: Deno's `IrohLoop` (a `node:net` socket on a
dup'd fd), Python's `_IrohLoop` (asyncio `add_reader`), Rust's `AsyncFd` task,
and Racket's `unsafe-file-descriptor->semaphore` park. Python, Rust, and Racket
each have a per-binding many-connection gate: `bindings-iroh-loop` runs
`python-iroh-loop`, `rust-iroh-loop`, and `racket-iroh-loop` together, the
binding siblings of `iroh-loop`; Deno implements the same park without a
`bindings-iroh-loop` member. What remains is a live 500k-connection socket run,
which still wants a load harness (`bench-peer-scaling` Phase 2). Two boundaries
remain on the cluster. **Goblins interop over iroh** is externally blocked, since
Goblins ships no iroh netlayer. A **native Zig QUIC** path stays rejected until
iroh's protocols stabilize and a production Zig QUIC stack exists (ADR-0055's
flip condition).

## Sessions above the socket

Crossed hellos lives above the socket. A driver registry detects duplicate peer
sessions, and the engine projects the typed abort without learning about sockets.
The upstream OCapN suite exercises that path through `zig build ocapn-conformance`.
Against live Goblins, a pancake actor called by a real Goblins client is proven
both as a settled call and as a pipelined enliven-and-call (ADR-0035). A full
three-party handoff — pancake as recipient, as gifter, and natively through
`driver.BlockingHost` — is proven end to end; the behavior, gates, and host-tier
mechanism live in [shipped.md](shipped.md). The boundary that remains here is
only that application code never sees the give or the second connection: every
binding's `connect` / `fetch` / `send` surface is the whole contract.

Cross-process redeem over iroh ships in every binding in both dial postures
(hinted `Direct`, and node-id-alone under a configured redeem posture). The
shipped story and its hermetic gates are in [shipped.md](shipped.md). The edges
that stay on this page are the ones that do not close under `check`: the
permanently-ungated `discovery_no_relay` live proof (above), the two-NAT
hole-punch seam the single-process gate cannot reach, and the live-socket 500k
measurement that `iroh-loop` does not claim. Knob names for the redeem posture
live in [`bindings/README.md`](../bindings/README.md).

The same three-party handoff runs all-pancake **over iroh**, the mesh.
`zig build iroh-mesh` stands up three iroh endpoints where A introduces B to C,
and B reaches C **by the gifted node id**, withdraws the gifted capability
through C's own bootstrap (C's engine verifying both certificates), and calls it.
B's one Ed25519 key is at once its node id, its keyed-session key, and the
`recipient-key` the gift names, so the recipient A introduced and the endpoint B
dialed C from are provably the same key. Dial-by-id reachability and key
unification together make a set of iroh connections a capability mesh, with no new
protocol below the handoff substrate.

Sturdyref enliven ships its initiator half (`engine.sturdyref`); its responder
half is the same inbound-`'fetch` serving path (`Peer.registerBootstrapCap`),
since an enliven is a `'fetch` against the local bootstrap exporter. Distributed
equality ships the in-memory substrate (`model.referencesEqual`). Container-type
Pass Invariant Equality ships too: `model.argumentsEqual` compares value trees
through List, Set, Tagged, and Struct shapes, Set equality order-agnostic (a
multiset) and Struct equality order-independent over its keys, so each compares
equal whichever codec's order carried it.

## The passable model and OCapN Null

The passable data model is complete except OCapN Null. `model.Argument` covers
bytes, string, symbol, keyword, integer, boolean, float64, void, list, set,
tagged, reference, error, handoff, and the OCapN Struct. That keyed-dictionary
passable rides both codecs (Syrup as a dictionary `{}`, Cap'n Proto as a
composite list of entry structs) with String-only keys, duplicate keys refused at
decode, and canonical key order on encode (ADR-0046). The Integer is
arbitrary-precision (ADR-0049): values in the i64 range ride the `integer` fast
path, anything larger rides the `big_integer` arm as a sign plus canonical
decimal digits, carried by both codecs, compared bytewise, and proven against a
live Racket bignum in the `goblins-interop` echo. OCapN Undefined is the `.void`
arm: Goblins marshals the unspecified value as the `<void>` record, and pancake
speaks the same record. Null is held fail-closed deliberately: Goblins has no
Null marshalling and the upstream encoding is unsettled, so inventing one would
not interop.

On the pipelining side, all three projection ops are answered. Receiving
`op:get`, `op:index`, or `op:untag` exports a promise at the new answer position,
and the engine resolves it to the Struct field, List element, or unwrapped Tagged
payload once the receiver settles
([ADR-0050](decisions/adr/ADR-0050-get-index-responder.md),
[ADR-0052](decisions/adr/ADR-0052-untag-responder.md)), following promise-shaped
resolutions and breaking on a missing field, an out-of-bounds index, a mismatched
tag, a wrong-shape value, or a broken receiver. Sending one installs the outbound
answer so the partner's resolve admits. The live `goblins-interop` gate pipelines
an `op:index` against a settled answer and an `op:get` against a still-pending
one, both of which a real Goblins vat resolves; Goblins has no `op:untag`
marshaller yet, so untag's pressure is the spec text, the Zig scenarios, and the
upstream-encoder fixture. `op:deliver-only` does not exist in the released v1.0
profile: a no-answer `op:deliver` is the one-way send, and `tell` uses it.

## The scalable I/O path

The scalable I/O path hosts and connects actors through driver APIs. The
completion loop takes per-connection hooks: `completion.Options.make_conn_ctx`,
`serve`, and `free_conn_ctx`. They bind an application context to each
connection, run it for every surfaced event, and free it at close. `net` stays
actor-agnostic; it owns no actor layer.

The bridge that feeds the byte-fed `driver.core.Host` from the TCP
completion loop ships as `driver.LoopBridge` (ADR-0076). The byte-fed
`driver.core.Host` stays the multi-connection tier, and the bridge is a
translator over it: the loop's per-connection hooks adopt each accepted peer
into the host (`Host.openAcceptedOver`, over `engine.Node.registerConnOver`,
so the loop's fixed slots keep their peers) and serve each polled event
through the host (`Host.serveEvent`), and the host's action queue drains
back into the loop. Both mechanisms that were open have landed.
Cross-connection outbound arming is `net.Loop.armOutbound`: a `flush` action
for connection B, queued while connection A was being served, arms B's
write — which is what puts a three-party deposit on the exporter's
connection, proven by the handoff-across-one-loop test in
`test/driver/loop_bridge_test.zig` and pinned at the net layer by
`test/net/completion_cross_arm_test.zig` (cross-armed bytes ride the
ADR-0042 queue accounting). The budgeted byte feed is
`Host.Options.local_turn_budget` over `Served.drivePostBatch`: one inbound
message that amplifies past the budget condemns the flooded connection with
a typed `resource_exhausted` abort and a `close` action for the embedder,
attributed to the connection whose vat amplified rather than to the verb
that fed the pump (`test/driver/host_budget_test.zig`). The live consumer is
the scale harness, `zig build tcp-loop`: one loop thread serving many
concurrent connections through the bridge, with churn, every reply asserted.

Two honest gaps remain at this seam. There is no loop-side dial executor: a
bridged host answers every `dial` action fail-closed, so it can mint a give
(the deposit rides an already-accepted exporter connection) but cannot yet
be a handoff *recipient*. And fan-in backpressure is per-connection only:
ADR-0042 parks a slow reader's own reads, but a many-A-to-one-B fan-in is
not throttled at its sources — B's read-park does not slow the As. A third
gap sits one layer up: blocking answer-waits (`BlockingHost.awaitVow`,
`ConnectedVat.settle`) still have no deadline, so a partner that opens then
stalls wedges the wait forever — the handshake budget on
`finishOpen(…, ?budget_ms)` is the pattern to extend, recorded in ADR-0076.

The loop is also tested under churn. Hundreds of connection lifecycles recycle
through a small slot pool, and abrupt mid-handshake drops exercise the teardown
path. Read buffers come from a shared backend-owned pool (io_uring provided
buffers, ADR-0054), so an idle connection holds no read-buffer memory and a frame
split across reads rides the same bounded spill as an oversize one.

Bootstrap capabilities are process-lifetime, not durable. If a host restarts, a
saved sturdyref re-enlivens against an empty registry until the app re-registers
the object.

Per-connection memory is the gated core state. The shared read-buffer pool
defaults to 256 buffers of 16 KiB (`Options.read_buffers`). The core's own part
of the budget is gated, not just measured: `engine.Peer` carries a compile-time
ceiling on its struct size, a test holds a warmed session's core state under
2 KiB per connection, and `zig build bench-peer-scaling` reports the live numbers
([ADR-0045](decisions/adr/ADR-0045-per-session-footprint-budget.md)). The
session-count arithmetic those budgets serve lives in the [ladder](ladder.md).

## Codecs

The Cap'n Proto codec ([`src/ocapn/codec/capnp/`](../src/ocapn/codec/capnp/),
[ADR-0026](decisions/adr/ADR-0026-hand-rolled-capnp-codec.md)) is
engine-integrated and selectable on a live session: a peer pair negotiates it
(`engine.pairing.pairedWithCodec`), and the handshake plus all later traffic ride
that codec through the codec-dispatch boundary (`session.codec`). The same choice
is reachable over the C ABI: `pancake_peer_new_negotiated` constructs the peer and
the tcp endpoints frame with the matching `PANCAKE_CODEC_*` value, and every
binding spells it in its own idiom. The session state machine is codec-neutral:
the Goblins-v1.0 resolver-callback translation is codec-blind, and the
deliver/resolve and bootstrap-fetch conformance scenarios produce identical
_observable_ traces on Syrup and Cap'n Proto. Authenticated `op:start-session`
verification uses the
profile-level canonical `<my-location …>` signing input, so Cap'n Proto sessions
do not get a weaker handshake. The two codecs trade off differently: Cap'n Proto's
frames are larger on the wire but lay every field at a fixed offset, while Syrup
is more compact, which matters most where many connections share one host.
`zig build bench-codec` reports the current encode/decode ns/op and MB/s for both
rather than freezing a ratio here.

One codec boundary is specific to three-party handoff. The handoff signing domain
is Syrup, not the session codec: a `desc:sig-envelope` signature covers the
**Syrup-canonical encoding of the decoded record**
(`codec.syrup.canonicalHandoffGiveSignedBytes`, single-sourced against the wire
encoder), so a re-encode stays signature-preserving
([ADR-0009](decisions/adr/ADR-0009-three-party-handoff-substrate.md),
[ADR-0003](decisions/adr/ADR-0003-codec-interoperability-posture.md)). This is a
spec invariant, since the OCapN `CapTP Specification.md` signs Syrup octets for
canonicalization, not a Goblins accommodation: two pancake peers on a Cap'n Proto
session still verify the handoff over Syrup-canonical bytes, re-canonicalizing the
give from its decoded fields. So hardcoding Syrup in the gifter's location-record
encoder
(`pancake_encode_peer_locator`, the signed-give builder) is correct regardless of
session codec, not a codec leak.

That cross-codec contract is gated. `reEncodeHandoff`
([`handoff_re_encode.zig`](../src/ocapn/engine/handoff_re_encode.zig)) takes a
decoded `model.Handoff` and the target session's codec/profile and emits the frame
that session would put on the wire, signature bytes riding along untouched in the
decoded fields. A gate drives it both directions: a give signed once over its
Syrup-canonical domain, encoded in each codec, decoded, re-encoded into the
*other* codec, decoded again, then re-canonicalized and re-verified, asserting the
re-derived signing domain reproduces the exact bytes the gifter signed
(`a signed handoff give re-encodes across codecs and its gifter signature still
verifies` in [`cross_peer_test.zig`](../test/engine/cross_peer_test.zig)). The
Cap'n Proto codec carries `desc:handoff-give` / `desc:handoff-receive`
structurally ([`encode.zig`](../src/ocapn/codec/capnp/encode.zig) /
[`decode.zig`](../src/ocapn/codec/capnp/decode.zig)); the gate proves the
decoded-field signing contract holds across that seam, not just in principle.

What remains Syrup-only is handoff **origination through a binding**: the C ABI
gifter origination helpers emit Syrup-encoded artifacts, so the transparent
three-party handoff a binding *starts* still ships as a Syrup-session feature
([ADR-0009](decisions/adr/ADR-0009-three-party-handoff-substrate.md) § Scope).
Re-encoding a give the engine already holds into any session's codec is no longer
the open edge; routing a binding-originated give onto a Cap'n Proto session is.

## Reference lifecycle and ocap patterns

The engine sends and accounts the wire-delta GC messages: an outbound
`op:gc-exports` or `op:gc-answers` decrements the matching table rows, and the
inbound side balances them (`session.retainSentExports`,
`applyGcExportDecrement`). Every binding drives those messages from a dropped
handle behind an opt-in, off by default (ADR-0063): a connection put into GC mode
(`with_gc` / `withGc` / `with-gc!`) registers a language finalizer on each far
reference returned by `fetch`, so when the collector reclaims the handle the
finalizer parks one `op:gc-exports` delta of 1 that the connection's own loop
drains to the wire on its next operation. The scope is deliberately just `fetch`
results, the one seam uniform across all four bindings; near refs, promises,
sturdyrefs (the enliven dedup cache owns those), the bootstrap import, and
redeemed handoff tokens are out of scope. With GC off, imports keep their table
rows until teardown. `test/engine/gc_churn_test.zig` proves the session reclaims
import rows flatly under churn.

Sturdyref enliven ships a one-call `enliven()` convenience in every binding, over
the `pancake_peer_prepare_enliven` / `pancake_peer_record_enlivenment` C ABI seam
(ADR-0012 dedup cache): one call parses the sturdyref, consults the cache, and on
a miss drives the bootstrap-fetch to settlement. A repeat enliven of the same
swiss-number on an open session short-circuits with no wire traffic. It is proven
against a live Goblins-published cap (`zig build goblins-interop`).

The ocap-pattern helpers, caretaker, attenuator, and revocation, are ordinary
actors built on one primitive, `Turn.forward` (ADR-0064). A behavior tail-forwards
its answer by returning a forward of `(target, verb, args)` instead of a value:
the vat resolves the caller's answer from that send, a local target near-calls
(composing, so a caretaker over an attenuator forwards twice in one turn), a far
target eventual-sends and defers the answer until the reply settles. Because the
proxy forwards by reference it wraps *any* target, near or wire-imported, so it is
wire-transparent, and because it is a plain actor it answers a near-call from its
own host exactly as it answers a partner's inbound delivery. The canonical
`actors.caretaker` / `actors.attenuate` are built on it, and every binding ships
the same primitive over its own serve loop (`caretaker`/`attenuate`, and the
Racket `conn-caretaker`/`conn-attenuate`/`conn-revoke!`): a behavior returns the
binding's forward value and the shared dispatch path tail-resolves it. The C ABI
stays the low-level deliver/resolve surface; a forwarding proxy is a binding-layer
actor composition, not a new wire op.

## The unbuilt driver

The second framework-shaped driver, `griddle`, a deterministic network simulator
and fuzzer, is not implemented. The [vision](vision.md) names what it will be;
nothing in the tree pretends it runs today.
