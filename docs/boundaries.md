# Boundaries

This page names where the implemented surface ends: the edges of
[what ships today](shipped.md). Every boundary here is deliberate, and most
are pinned by a test or an ADR, so none of them is a silent gap. The plan for
moving these lines lives in the [ladder](ladder.md) and the
[roadmap](roadmap.md).

## Netlayer

`net` ships the netlayer contract and the stream framing; CapTP itself stays
transport-agnostic above it. One parser finds frame boundaries for the active
codec ([ADR-0029](decisions/adr/ADR-0029-one-parser-stream-framing.md)).
`net.tcp` and `net.tcp_keyed` are cleartext TCP residents; the socket is an
implementation detail of those two symbols, not of CapTP. `net.tcp` proves a
real-socket handshake, a bootstrap fetch, and a call against a live Goblins
vat ([ADR-0035](decisions/adr/ADR-0035-live-goblins-interop.md)). The C ABI
re-exposes the socket path as blocking endpoint handles behind a
`last_error` boundary
([ADR-0030](decisions/adr/ADR-0030-netlayer-connection-and-memory-posture.md)).

A fourth symbol, `keyed-tcp`
([ADR-0075](decisions/adr/ADR-0075-keyed-tcp-designator.md)), reuses those
same sockets and only changes the locator grammar: the designator is the
listener's Ed25519 key in hex, the socket address rides a
`direct-addresses` hint, and the driver pins the handshake to the dialed key.
A partner can re-dial the same designator after a restart with just the hint
updated, and a key squatter is refused before the session opens.

That pin buys less than encryption. The channel stays cleartext, so anyone
on the path reads every frame, and since the signature only covers the
static location bytes, an active middlebox can relay the real listener's
signed hello and then read or alter ordinary traffic afterward. What it does
guarantee is that only the real key holder can produce a fresh signature for
minting or redeeming a handoff certificate; confidentiality and integrity
for the channel itself stay iroh's job.

Cap'n Proto encodes and decodes non-empty locator hints on both
`op:start-session` and sturdyref locators (lazy `hint_list` into `toOwned`),
so a keyed-tcp or iroh peer advertising a `direct-addresses` hint can open a
Cap'n Proto session. Syrup does the same on borrowed start-session and
sturdyref views (`hint_list` + `toOwned`), and still captures
`acceptable_location_raw` as the signing domain. Every binding
ships the keyed-tcp surfaces, and `bindings-keyed-tcp-restart` verifies the
restart-after-key-pin claim per binding. A flattened handoff exporter locator
that lost its original signed bytes still re-parses to empty hints; that
residual is named under Handoff below.

Read buffers size the steady state, not the largest admissible frame. A frame
that outgrows the buffer assembles once in a bounded, owned spill that frees
when it drains, so per-connection memory does not scale with
`max_frame_bytes`
([ADR-0041](decisions/adr/ADR-0041-bounded-inbound-spill.md)). The completion
loop bounds the outbound side the same way: once pending reply bytes cross a
high-water mark, the connection stops arming reads until the partner drains
them ([ADR-0042](decisions/adr/ADR-0042-outbound-high-water-backpressure.md)).

The encrypted iroh resident offers a blocking sidecar path for single
connections and a completion-loop path
([ADR-0057](decisions/adr/ADR-0057-iroh-completion-loop-bridge.md)) serving
many QUIC connections from one thread over the sidecar's readiness
descriptor. `zig build iroh-loop` proves that multiplexing is correct, not
that its memory is bounded: the loop-driven per-connection cost is the
`served` row of `bench-peer-scaling`, reported (roughly 1.1 GiB for 500k
connections) but not held by a build check. The checked budget is the warmed session that
`test/engine/footprint_budget_test.zig` holds at or under 2 KiB. TLS over
plain TCP is not implemented
([ADR-0055](decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)). The blocking
pump stays a single fiber by contract; a partner that streams without
draining rides the completion loop instead
([ADR-0053](decisions/adr/ADR-0053-blocking-pump-single-fiber.md)).

Cleartext TCP and encrypted iroh QUIC share the same CapTP semantics;
`inproc` is socket-free. iroh rides the netlayer contract behind a Rust
sidecar staticlib, so the pure-Zig archives stay pure Zig (ADR-0055), proven
live pancake to pancake by `zig build iroh-interop`. One Ed25519 key is at
once a peer's iroh node id, its OCapN locator designator, and its session
signing key, enforced on the native dial path where the engine refuses any
other key at the handshake (ADR-0075). Dial-by-id and durable-identity
claims beyond that are shipped capabilities, catalogued in
[shipped.md](shipped.md), not boundaries.

Dial-by-id also reaches across the public internet. The opt-in
`zig build iroh-reachability` step, and each binding's opt-in
`bindings-iroh-reachability` check steps, dial by node id alone through n0's
relays and DNS/pkarr; they stay out of `check` because publish-propagation
timing makes them unfit as in-tree verification. The `discovery_no_relay` posture
stays deliberately unchecked: reaching a no-relay node by id needs that node
to own a publishable direct address, which a NAT'd host or container lacks,
so the check step would be permanently red even though a dialer still settles and
retries under that posture. One seam stays named on purpose: the discovery
proof runs both endpoints on one host, so it proves discovery and relay
reach but not hole-punching between two distinct NATs, which would need the
two halves on separate networks.

iroh serves at scale, in Zig and in every binding, on the event-driven
completion loop of ADR-0057: many connections ride one loop thread rather
than one apiece, and the public C ABI exposes only that loop-only path.
`bindings-iroh-loop` proves it for all four bindings. Two boundaries remain
on the cluster: Goblins interop over iroh is externally blocked, since
Goblins ships no iroh netlayer, and a native Zig QUIC path stays rejected
until iroh's protocols stabilize and a production Zig QUIC stack exists,
ADR-0055's flip condition.

## Sessions above I/O

Crossed hellos are caught above the netlayer, at the driver and host tier,
proven through `zig build ocapn-conformance`. The full three-party handoff
is proven end to end and catalogued in [shipped.md](shipped.md); the
boundary that stays here is narrow: application code never sees the give or
the second connection, so every binding's `connect` / `fetch` / `send`
surface is the whole contract.

CapTP session lifecycle is three states — `negotiating | open | closed`
([ADR-0083](decisions/adr/ADR-0083-outbound-abort-closes-session.md)). There
is no CapTP `draining`. Outbound aborts commit through
`Peer.commitAbortOutbound`: after a successful queue push, `.close`
dispositions close the session; handshake refusals use
`.keep_negotiating` (`CaptpVersionMismatch`, bad signature, partner-key
mismatch) and leave an abort frame for the partner. When encode fails on a
`.close` disposition, the session still closes so a fatally refused peer does
not stay open. Host soft-stop
(`condemned` + flush/close) stays a transport concern above CapTP.
`FeatureSet` carries only bits checked in validate
(`pipelining`, `handoff`, `wire_delta`, `sturdyref`); there is no advertised
`stream` or `equality` flag. Session-pair uniqueness is Host enrollment
posture (ADR-0012), not a `FeatureSet` bit: a second dial to a partner that
already has a live dialed CapTP session enrolled refuses
`HostError.SessionPairExists`. Crossed hellos may still open an accepted
session while a dial to the same partner is in flight (ADR-0030). Structural
equality still assumes same-session positions.

There is no typed peer listen-send export: `PANCAKE_EVENT_LISTEN` is
engine-synthesized for V1.0 projections and installed on inbound, held by the
EVENT/send parity allowlist in `zig build meta-check`. Listen on imported
promises and on promise targets named as `desc:export` ships
([ADR-0009](decisions/adr/ADR-0009-three-party-handoff-substrate.md)); the
upstream suite's `op_listen` module exercises that path. Listen on a live object
export (held `local_value`, no inbound answer) fires fulfill of that export
immediately. Listen on an unresolved promise export without an answer row still
refuses loud (`UnexpectedMessage`) — that export-side promise-listen path is
the remaining ADR-0007 boundary.

Cross-process redeem over iroh ships in every binding under both dial
postures; the shipped story is in [shipped.md](shipped.md). What stays on
this page are the edges that do not close under `check`: the
permanently-unchecked `discovery_no_relay` proof above, the two-NAT
hole-punch seam a single-process check step cannot reach, and the live-socket 500k
measurement that `iroh-loop` does not claim.

The same handoff also runs all-pancake over iroh, the mesh:
`zig build iroh-mesh` has A introduce B to C, then B reaches C by the gifted
node id alone and calls it, with C's engine verifying both certificates. That
relies on the same key unification as above, so no new protocol sits below
the handoff substrate.

## The passable model and OCapN Null

The passable data model is complete except for OCapN Null. `model.Argument`
covers every OCapN shape, including a keyed-dictionary Struct that rides both
codecs with string-only keys, duplicate keys refused at decode, and
canonical key order on encode
([ADR-0046](decisions/adr/ADR-0046-struct-passable.md)). The Integer is
arbitrary-precision: values in the i64 range take a fast path, and larger
ones ride a `big_integer` arm proven against a live Racket bignum
([ADR-0049](decisions/adr/ADR-0049-arbitrary-precision-integer.md)). Null has
no model arm on purpose: Goblins has no Null marshalling yet and the
upstream encoding is unsettled, so inventing one would not interop with
anything. Unknown Syrup records project as `Tagged` (Goblins break/exception
leniency); that is not a dedicated Null refuse. The codec proof is
`test/codec/syrup_test.zig` ("foreign record argument as Tagged"), not a
Null-shaped decode error.

On the pipelining side, all three projection operations are answered.
Receiving `op:get`, `op:index`, or `op:untag` exports a promise that the
engine resolves once the receiver settles
([ADR-0050](decisions/adr/ADR-0050-get-index-responder.md),
[ADR-0052](decisions/adr/ADR-0052-untag-responder.md)), breaking cleanly on a
missing field, an out-of-bounds index, a mismatched tag, or a broken
receiver. The live `goblins-interop` check step pipelines an `op:index` against a
settled answer and an `op:get` against a pending one as the asker: pancake
sends the ops and a real Goblins vat resolves both. It does not prove
Goblins-as-asker against pancake's in-tree responders (those ride Zig
scenarios and the suite). Goblins has no `op:untag` marshaller yet, so untag's
proof is the spec text, the Zig scenarios, and the upstream-encoder fixture
alone.
`op:deliver-only` does not exist in the released v1.0 profile: a no-answer
`op:deliver` is the one-way send, and `tell` uses it.

## The scalable I/O path

The completion loop hosts and connects actors through per-connection hooks
(`make_conn_ctx`, `serve`, `free_conn_ctx`) that bind an application context
to each connection and free it at close. `net` stays actor-agnostic and owns
no actor layer of its own.

`driver.Bridge`
([ADR-0076](decisions/adr/ADR-0076-loop-fed-host-bridge.md)) feeds the
byte-fed `driver.core.Host` from the TCP completion loop: the loop adopts
each accepted peer into the host, serves each polled event through it, and
drains the host's action queue back into the loop. Cross-connection outbound
arming, `Loop.armOutbound`, lets a flush action queued for one connection
still arm another connection's write, which is what puts a three-party
deposit on the exporter's connection, proven in
`test/driver/bridge_test.zig` and `test/net/completion_cross_arm_test.zig`.
The budgeted byte feed, `Host.Options.local_turn_budget`, condemns a
connection whose inbound message amplifies past budget with a typed
`resource_exhausted` abort, attributed to the amplifying connection rather
than the verb that fed the pump (`test/driver/core_host_budget_test.zig`).
`zig build tcp-loop` is the live consumer: one loop thread serving many
concurrent connections through the bridge under churn.

Blocking answer-waits ship deadlines (`settle_timeout_ms` raises
`Error.WaitTimedOut`, `Loop.runUntil`'s deadline raises `error.Timeout`, both
unbounded at zero). Beyond per-connection park (ADR-0042), the completion loop
offers opt-in fan-in source throttle and park-duration kill
([ADR-0082](decisions/adr/ADR-0082-adapter-continuity-and-host-resource-honesty.md)):
when a sink is parked, sources slow (pinned by the fan-in N→1 test in
`test/net/completion_loop_test.zig`), and a connection that stays parked past
`park_kill_ms` closes with `CloseReason.park_kill`. Loop-side dial, a handoff
recipient redeeming from one loop thread, ships for both TCP and iroh, verified by
the redeem theorem in `test/driver/bridge_test.zig` and by
`zig build iroh-bridge-redeem`.

### ADR-0081 / ADR-0082 residual (adapter resilience)

Contract inventory so the next audit does not re-flag intentional swallows:

| Item | Status |
|------|--------|
| Handshake `handshake_timeout_ms` becomes `HandshakeTimedOut` | shipped |
| Keepalive full-window-or-nothing (timer rollback + unsupported-OS disable) | shipped |
| Dead-peer reclaim / `on_close` under `run` | shipped |
| DialError axis + iroh classify | shipped; double-OOM dropping a second `ConnectDone` append is a named residual |
| Bridge `dialFailed` under `catch {}` after `return err` | **by-design** — reporting best-effort; dial error surfaces |
| C `pancake_host_session_release` void + `last_error` | **by-design** — documented C ABI |
| Stateless GC `sendCopying` best-effort | **by-design** — session tables own counts (ADR-0008) |
| Vat forward / node withdraw settle `catch {}` | **by-design** — partner disconnect backstop |
| `failDispatch` flush nudge `catch {}` | **by-design** — must not mask the dispatch error |
| Settle / `Loop.runUntil` deadlines | shipped (`WaitTimedOut` / `error.Timeout`) |
| `ResilientClient` dial policy (ADR-0082) | shipped — Zig unit tests plus iroh-reachability and binding discovery share the classifier and budget; rebuild is a new CapTP session, not a Session facade |
| Fan-in source throttle (ADR-0082) | shipped — `Loop.Options.fan_in_throttle` (default off); fan-in proof in `test/net/completion_loop_test.zig`; sources re-arm when the last sink drains |
| Park-kill + `CloseReason.park_kill` (ADR-0082) | shipped — reclaim plus typed `on_close` reason |
| Host full `SessionLimits` (ADR-0082) | shipped at Zig Host mint; C ABI exposes `frame_cap` and `pancake_host_set_session_limits` |
| Bootstrap durability posture | `ephemeral` live; `Host.init` panics on `durable_bootstrap` until an embedder store lands (see Bootstrap below) |

The host runs each `engine.Node.Action` inside a Host-private pump
(`src/driver/core/host_pump.zig`). Settles, fails, and flushes are consumed
there; only a dial or a gift-id draw is re-queued for the embedder, because
a node row can die at the node's next pop while an embedder row has to
survive until the embedder's own next drain. Those are two contracts with
different lifetimes riding one `engine.ActionFifo` mechanism, not one spine
written twice, so merging them into a single owner is rejected outright, not
deferred.

The loop is also tested under churn: hundreds of connection lifecycles
recycle through a small slot pool, and abrupt mid-handshake drops exercise
the teardown path. Read buffers come from a shared, backend-owned pool
([ADR-0054](decisions/adr/ADR-0054-shared-read-buffer-ring.md)), so an idle
connection holds no read-buffer memory.

Bootstrap capabilities default to the `ephemeral` Host durability posture:
they last only as long as the process. If a host restarts, a saved sturdyref
re-enlivens against an empty registry until the application re-registers the
object. ADR-0082 names an opt-in `durable_bootstrap` posture. Selecting that
arm at `Host.init` fails closed with a panic until an embedder store is wired,
so it cannot silently behave as ephemeral. When a first-party consumer needs
it, the store contract is:

- The embedder owns persistence (disk, DB, or sealed blob) of swiss-number to
  local object identity bindings across Host process restart.
- On Host start with `durable_bootstrap`, the Host reloads that map before
  accepting sessions. CapTP wire stays unchanged; there is no log replay.
- A restart proof verifies the posture as shipped: a sturdyref must survive Host
  teardown and re-init under the same store.

That gap is Host-above-CapTP durability, not wire replay.

Per-session CapTP core memory is a checked budget, not just a measured one:
`engine.Peer` carries a compile-time ceiling on its struct size, a test holds
a warmed session's core state at or under 2 KiB, and
`zig build bench-peer-scaling` reports the live numbers
([ADR-0045](decisions/adr/ADR-0045-per-session-footprint-budget.md)).
Transport buffers sit per-connection on top of that core budget. The
session-count arithmetic those budgets serve lives in the
[ladder](ladder.md).

## C ABI archive resolve

Bindings resolve the à-la-carte C archives through a publishable cascade
([ADR-0077](decisions/adr/ADR-0077-publishable-c-abi-resolve.md)): each
package downloads language-natively via
[`bindings/c-abi-resolve.json`](../bindings/c-abi-resolve.json), and
`releases_published` in that contract is the valve that turns on cold-cache
network fetch for consumers. Hygiene and security refusals, a non-HTTPS URL
without a typed escape, a checksum miss, a zip-slip or link member, always
fail closed; soft-fail only covers a missing network or tool when the fetch
was optional. Windows release-pack is not a published leg yet, so Windows
consumers need `PANCAKE_LIB_DIR` or an in-tree `zig-out` until that matrix
exists.

## Codecs

The Cap'n Proto codec ([`src/ocapn/codec/capnp/`](../src/ocapn/codec/capnp/),
[ADR-0026](decisions/adr/ADR-0026-hand-rolled-capnp-codec.md)) is
engine-integrated and selectable on a live session; a peer pair negotiates
it, and the handshake plus all later traffic ride that codec. The session
state machine itself is codec-neutral, so the deliver-and-resolve and
bootstrap-fetch oracle cross-codec scenario traces produce identical
observable results on Syrup and on Cap'n Proto. The two codecs trade off differently: Cap'n
Proto's frames are larger but lay every field at a fixed offset, while Syrup
is more compact, which matters most where many connections share one host.
`zig build bench-codec` reports the current numbers rather than freezing a
ratio here.

One codec boundary is specific to three-party handoff. The handoff signing
domain is always Syrup, never the session codec: a `desc:sig-envelope`
signature covers the Syrup-canonical encoding of the decoded record, so a
re-encode stays signature-preserving
([ADR-0009](decisions/adr/ADR-0009-three-party-handoff-substrate.md),
[ADR-0003](decisions/adr/ADR-0003-codec-interoperability-posture.md)). That
follows the OCapN spec, which signs Syrup octets for canonicalization
regardless of session codec, so two pancake peers on a Cap'n Proto session
still verify the handoff over Syrup-canonical bytes. A scenario proves it: a
give signed once, encoded in each codec, decoded, re-encoded into the other
codec, decoded again, and re-verified reproduces the exact bytes the gifter
signed (`test/engine/cross_peer_test.zig`), even though Cap'n Proto carries
`desc:handoff-give` and `desc:handoff-receive` structurally rather than as
an opaque blob.

The C ABI's gifter helper (`pancake_build_handoff_give`) still emits a
Syrup-encoded envelope, since the signing domain is always Syrup, but the
send path now decodes it into a fully typed `model.HandoffGive` first, so a
Cap'n Proto session encodes those typed fields instead of shipping an empty
give. One residual remains: a locator flattens to a plain
`transport:designator` string whenever the original signed bytes do not
ride along, and that flattened form always re-parses to an empty hint, so a
give naming a keyed-tcp or iroh self-locator cannot re-verify past a Cap'n
Proto session without those original bytes. That is a property of the
flattened-string representation, not something this closes.

## Reference lifecycle and ocap patterns

The engine sends and accounts the wire-delta GC messages, and every binding
drives them from a dropped handle behind an opt-in, off by default
([ADR-0063](decisions/adr/ADR-0063-finalizer-driven-distributed-gc.md)): a
connection in GC mode registers a language finalizer on each far reference a
`fetch` returns, and reclaiming that handle parks a GC delta the connection's
own loop drains on its next operation. The scope is deliberately just
`fetch` results; near refs, promises, sturdyrefs, the bootstrap import, and
redeemed handoff tokens are out of scope, and with GC off, imports keep
their table rows until teardown. `test/engine/gc_churn_test.zig` proves the
session reclaims import rows flatly under churn.

Sturdyref enliven ships a one-call `enliven()` in every binding over a C ABI
dedup cache
([ADR-0012](decisions/adr/ADR-0012-sturdyref-shape-and-enliven.md)): a
repeat enliven of the same swiss number on an open session short-circuits
with no wire traffic, proven against a live Goblins-published cap.

The ocap-pattern helpers, caretaker, attenuator, and revocation, are
ordinary actors built on one primitive, `Turn.forward`
([ADR-0064](decisions/adr/ADR-0064-answer-forwarding-and-ocap-proxies.md)),
shipped identically in every binding. The C ABI stays the low-level
deliver-and-resolve surface; a forwarding proxy is a binding-layer
composition, not a new wire op.

## Access and responsibility held as present boundaries

One real ownership gap remains open on purpose, left for its own structural
move rather than closed in passing: `host_pump.zig` stays a Host-private,
import-gated file instead of being merged back into `host.zig`.

## The unbuilt driver

The second framework-shaped driver, `griddle`, a deterministic network
simulator and fuzzer, is not implemented. The [vision](vision.md) names what
it will be; nothing in the tree pretends it runs today. Start it only when
fuzz or simulation is the cheapest way to prove a net or driver claim that the
live Goblins and `ocapn-conformance` check steps cannot reach, and never inside the
sans-io core.

Adapter continuity (`driver.ResilientClient`, ADR-0082) is shipped. Further
binding or demo polish lands only from a named demo or accountability failure,
with a test or check step in the same change, not as an open-ended pass.

## Product CLI edges (ADR-0084)

The installable `pancake` binary under `cli/` ships A-v1: operability,
progressive everyday `ocapn`, curated MCP, and `app bot`. It does not yet ship
A2A-on-CapTP or its HTTP facade (`app a2a`), griddle, ocapnviz,
`ocapn trace --ws`, or OTEL export. Day-one CapTP introspection is `ocapn info`
only; refs-tier and richer introspect verbs are planned, not registered, and
are not advertised as aliases. CapTP dial/listen use a non-zero handshake and
settle budget so a silent partner fails with exit code `timeout` instead of
parking. `listen` carries `mcp: never` (absent from every MCP catalog) because
it parks on accept; CapTP verbs also refuse it on non-argv fronts. Process
context uses an explicit `Front` + `Sink` (not a nullable capture pointer).
SIGTERM/SIGINT drain `ocapn listen` and `mcp` via a shared Io closer. CapTP
identity state takes an exclusive advisory lock on `STATE_DIR/lock` (exit
`busy` on contention). MCP applies finite idle and max-session caps (defaults
30m / 8h; `--idle-ms` / `--max-session-ms` or env overrides; `0` disables). The
`rooms-bot` install name is a thin exec/forward shim to `pancake app bot` (no
CapTP/iroh link); `zig build rooms-bot` runs the product binary directly.
`app bot` shares the product SIGTERM latch and mints a stable Host seed under
`DIR/identity` (or `--identity`).
