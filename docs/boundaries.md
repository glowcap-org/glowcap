# Boundaries

This page lists the edges of [what ships today](shipped.md). Most are pinned
by a test or an ADR; the [ladder](ladder.md) and [roadmap](roadmap.md) say how
each one moves.

## Netlayer

[architecture](architecture.md#netlayer-net) explains how transports and
framing fit; [shipped](shipped.md) lists what ships. These edges remain open:

- **Cleartext TCP / keyed-tcp.** Anyone on the path can read frames.
  Keyed-tcp pins the handshake key; it is not encryption. Confidentiality
  and channel integrity are iroh's job
  ([ADR-0075](decisions/adr/ADR-0075-keyed-tcp-designator.md)).
- **No TLS over plain TCP.** Encryption is the iroh resident
  ([ADR-0055](decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)).
- **iroh loop memory.** `iroh-loop` / `bindings-iroh-loop` prove multiplexing,
  not a checked per-connection RSS budget. The checked floor is the warmed
  session footprint test (~2 KiB core state).
- **`discovery_no_relay` unchecked.** A no-relay dial-by-id needs a
  publishable direct address; typical NAT/containers lack one, so that
  posture is not a green check step.
- **Discovery proof is single-host.** Opt-in `iroh-reachability` /
  `bindings-iroh-reachability` prove discovery and relay reach, not
  hole-punching between two distinct NATs.
- **No Goblins-over-iroh.** Goblins ships no iroh netlayer.
- **No native Zig QUIC.** Rejected until iroh's protocols stabilize and a
  production Zig QUIC stack exists (ADR-0055 flip condition).
- **Blocking pump is one fiber.** Partners that stream without draining
  belong on the completion loop
  ([ADR-0053](decisions/adr/ADR-0053-blocking-pump-single-fiber.md)).

## Sessions above I/O

[architecture](architecture.md#application-surface-driver) explains how Host,
Session, and handoff fit; [shipped](shipped.md) lists what ships. The edges:

- **App surface is the whole contract.** With a Host, ordinary
  `connect` / `fetch` / `send` never sees the give bytes or the second
  connection; the call settles as the introduced capability.
- **No CapTP `draining`.** Lifecycle is `negotiating | open | closed`
  ([ADR-0083](decisions/adr/ADR-0083-outbound-abort-closes-session.md)).
  Host soft-stop (`condemned`) is transport above CapTP.
- **No advertised `stream` / `equality` FeatureSet bits.** Validated bits
  only: `pipelining`, `handoff`, `wire_delta`, `sturdyref`.
- **Session-pair uniqueness is Host enrollment**, not wire equality
  (ADR-0012): second dial to a live partner session, or keyed dial to a
  verified partner key, refuses `HostError.SessionPairExists`. An accepted
  tcp designator does not squat dial availability. Crossed hellos may still
  race an in-flight dial (ADR-0030).
- **`127.0.0.1` vs `[::1]` can open two sessions** until the partner-key
  index wins. Keyed-tcp and iroh pin by key.
- **One owning C session family.** The one-call blocking C session verbs
  (`pancake_tcp_session_*`,
  [ADR-0062](decisions/adr/ADR-0062-one-connect-over-a-netlayer-slice.md)) are
  spelled on the tcp archive alone. A second transport does not copy that
  family: before an owning inproc or iroh session surface lands, the session
  choreography moves to one transport-neutral home and the transports keep
  only their connect constructors. `zig build meta-check` refuses the copied
  spelling until that move happens.
- **Foreign promise as `send`/`tell` arg is refused** (`ForeignArgument`).
  Object foreign fulfills stay on gift-redeem. Listen on a bare unresolved
  promise export is refused; third-party promise listen is the ADR-0009
  proxy path (`Node.proxyForeignPromiseFulfill`,
  `test/engine/node_test.zig`; settlement relay
  `Peer.applyRelayedResolution`, `test/engine/relay_resolution_test.zig`).
- **Open under `check`:** the netlayer edges above (`discovery_no_relay`,
  two-NAT hole-punch, live-socket 500k RSS) stay open; `iroh-loop` does not
  claim them.

## The passable model and OCapN Null

What the model covers: [shipped](shipped.md). Edges:

- **No OCapN Null arm.** Goblins has no Null marshalling yet; inventing one
  would not interop. Unknown Syrup records project as `Tagged`.
- **Set and Keyword go beyond the draft Model.** The pinned Model.md lists no
  Set container and no Keyword atom; Goblins marshals both over Syrup, and
  pancake follows that wire (canonical set order with duplicate refusal, the
  Goblins `<kw …>` keyword record) rather than the narrower draft list.
- **Goblins-as-asker against pancake's `op:get` / `op:index` / `op:untag`
  responders** is not the live `goblins-interop` proof. In-tree Zig scenarios
  and the reference fixtures cover the responders; the upstream suite carries
  no projection ops, and Goblins has no `op:untag` marshaller yet. The
  driver's asker bracket proves only that pancake accepts canonical `op:get` /
  `op:index` frames a Goblins netlayer wrote, not that Goblins observed the
  settlements.
- **No `op:deliver-only` in released v1.0.** One-way send is no-answer
  `op:deliver` (`tell`).

## Scalable I/O and Host durability

[architecture](architecture.md#application-surface-driver) explains how the
Bridge and the completion loop work; [shipped](shipped.md) names the proofs
(`tcp-loop`, `iroh-bridge-redeem`). The edges:

- **`durable_bootstrap` panics at `Host.init`** (a loud unsupported-posture
  stop, not a typed error) until an embedder store lands (ADR-0082). Default is
  ephemeral: sturdyrefs die with the process.
- **Named residual:** double-OOM dropping a second `ConnectDone` append
  (ADR-0081 / ADR-0082).
- **Two action-queue lifetimes** (node pop vs embedder drain) stay split on
  purpose, not a deferred merge (`host_pump.zig`).
- **Binding outbound flush copies** (TS/Python/Racket copy-then-release vs
  Rust hold-across-write) are a named memory-rule cost.
- **Zero settle / loop deadlines are unbounded** (`settle_timeout_ms` /
  `Loop.runUntil`); product CLI never leaves them at zero.

## C ABI archive resolve

The archive resolve cascade is
[ADR-0077](decisions/adr/ADR-0077-publishable-c-abi-resolve.md)'s contract,
pinned by [`bindings/c-abi-resolve.json`](../bindings/c-abi-resolve.json).
Hygiene refusals fail closed. Windows release-pack is not a published leg yet,
consumers need `PANCAKE_LIB_DIR` or in-tree `zig-out`.

## Codecs

The site Codecs page (`zig build docs-serve`) teaches the tradeoffs;
[shipped](shipped.md) lists what ships. The edges:

- **Handoff signing domain is always Syrup**, even on a Cap'n Proto session
  ([ADR-0009](decisions/adr/ADR-0009-three-party-handoff-substrate.md)).
- **No frozen “N× faster” ratio**. `zig build bench-codec` reports numbers.

## Reference lifecycle

[shipped](shipped.md) lists what ships here (opt-in GC, enliven dedup,
caretaker and attenuate). The edges:

- **GC scope is `fetch` results only** (ADR-0063); near refs, promises,
  sturdyrefs, bootstrap, redeemed handoffs stay out.
- **Forwarding proxies are binding-layer composition**, not a new wire op
  (ADR-0064). The C ABI stays deliver-and-resolve.

## Host-private modules

`host_pump.zig` is an intentional Host-private size boundary: pump mechanics
(drain, dirty, action queue helpers) live beside `host.zig`, and only
`src/driver/core/host.zig` may import it (`zig build meta-check` enforces the
allowlist). That split is settled product shape, not unfinished ownership.

## The unbuilt driver

The second framework-shaped driver, `griddle`, a deterministic network
simulator and fuzzer, is not implemented. The CLI exposes a brand placeholder
(`pancake griddle status|help`) so the subtree name is locked; the sim runtime
is not. The [vision](vision.md) names what it will be. Start the runtime only
when fuzz or simulation is the cheapest way to prove a net or driver claim that
the live Goblins and `ocapn-conformance` check steps cannot reach, and never
inside the sans-io core. Topology visualization (ocapnviz) is not
implemented; it would consume griddle's timeline feeds. The CapTP lab
(`pancake repl`) stays a separate UI.

Adapter continuity (`driver.ResilientClient`, ADR-0082) is shipped. Further
binding or demo polish lands only from a named demo or accountability failure,
with a test or check step in the same change, not as an open-ended pass.

## Product CLI edges (ADR-0084)

Recipes: [`docs/cli.md`](cli.md). What ships on the product binary lives there
and in [shipped](shipped.md). Edges that are still open: no A2A-on-CapTP
(`app a2a`), no griddle **sim runtime** (`pancake griddle` is a status
placeholder), no ocapnviz, no `ocapn trace --ws`, no OTEL export, no
PowerShell completion, no typo suggestions. CapTP `listen` is argv-only
(never an MCP tool) because it parks on accept. Silent partners fail with
exit `timeout` (finite handshake/settle budgets), not an unbounded hang.
`ocapn listen` stops by polling `Listener.waitAcceptable` against the shared
stop latch, never by closing the listen FD from another thread (Zig threaded Io panics on that BADF).
