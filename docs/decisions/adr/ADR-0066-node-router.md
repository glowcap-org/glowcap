---
id: ADR-0066
status: accepted
date: 2026-06-19
tags: [driver, handoff, three-party, node, c-abi, bindings]
decision: "The cross-connection handoff router is sunk into a sans-io `engine.Node` in the Zig core (at acceptance also re-exported as `driver.Node` for native ergonomics; that re-export is deleted (ADR-0079): it owns the connection table keyed by integer `conn_id`, one node-owned `engine.Peer` per connection, the retained node `seed`, the shared `engine.bootstrap.GiftRegistry`, and the redeemed / foreign-home routing tables, and at acceptance was projected through the C ABI as pancake_node_* in the sans-io `libpancake_ocapn` (that C waist is deleted; CapTP multi-connection product work uses `pancake_host_*` only). It lives in the engine core, not the I/O-bearing driver, because it is pure routing data and the sans-io archive must project it without dragging in a transport. The router is removed from each binding `Machine`) the duplicated protocol tables sink into the node: leaving a thin handle that holds only host-idiom residue (the dialed-exporter cache, the `conn_id`-to-command-channel map, the giftable factories, the redeem-reachability posture) over a vat addressed by `conn_id`. The vat (turn loop, promise resolution, await, behavior dispatch) stays in the binding; only the router sinks."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0079, ADR-0100]
---

# ADR-0066 The cross-connection handoff router is a sans-io node

> ADR-0100 removes the shared `GiftRegistry` from Node. Node keeps the live
> session directory and authority-neutral dependencies keyed by
> `(Gifter–Exporter PeerId, fixed-size gift tag)` to only the receiver Peers
> parked on that exact gift; each Peer owns its session's gifts, scalar replay
> counters, and exact-keyed pending groups.

> **C-projection amendment.** The Zig `engine.Node` router and its semantics
> remain accepted. The former pancake_node_* C projection in libpancake_ocapn
> was deleted: CapTP multi-connection product work uses `pancake_host_*` only.
> Historical Consequences text below that names that C family describes the
> shape at acceptance time, not the current public C surface.
>
> **Vocabulary amendment (ADR-0079).** Living guidance no longer equates
> binding `Node` with `engine.Node`. The multi-conn product is `Host` /
> `PancakeHost` / binding `Host`; `engine.Node` is the router Host owns. Binding
> CapTP partner is `Session`. Read historical “binding Node” / `driver.Node`
> re-export text below as the shape at acceptance time. The Follow-on section’s
> “binding handle is Node” claim is likewise historical: that handle is now
> binding `Host`.

## Context

The three-party handoff router. Goblins' `mycapn`, the thing distinct from a
per-partner connection: existed four times: once in each binding's `Machine`
(Rust [`bindings/rust/src/session.rs`](../../../bindings/rust/src/session.rs),
and its Python/TypeScript/Racket peers), in two divergent designs, and nowhere
in native Zig. Each copy holds the same state: a retained node `seed` reused for
every connection (so an exporter verifies a `desc:handoff-receive` against one
key), a `redeemed` map from a synthetic far token to the exporter connection that
hosts it, a `foreign_homes` map from a fetched import to its home connection (so
a published actor returning a far cap from elsewhere re-gifts instead of
mis-encoding a cross-connection reference), and the shared
`engine.bootstrap.GiftRegistry`
([ADR-0056](ADR-0056-vat-scoped-gift-registry.md)) that lets a deposit on the
gifter session meet a withdraw on the recipient session. (The binding's
`giftables` (a name-to-behavior-factory map republished on each connection) is
*not* part of this router: a factory mints a host behavior, so it is vat-side
under the boundary below and stays in the binding.)

A protocol-or-correctness decision copied N times is a latent inconsistency,
the two binding designs had already drifted on the redeemed-token encoding. The
router could not sink because every route value pointed at a *language*
connection object (a `tokio` channel, an `asyncio` task). The native Zig
`BlockingSession` had no router at all.

The conformance host
([`conformance/ocapn-conformance/pancake_peer.zig`](../../../conformance/ocapn-conformance/pancake_peer.zig))
was not a fifth copy of this router: its then-`GifterHub` was a *host-thread*
mechanism: it served each connection on its own thread and handed a gifter
request/result between threads under a mutex, while each thread still called the
engine handoff primitives (`engine.handoff_recipient.signedReceiveFromGiveBytes`)
and shared one `engine.bootstrap.GiftRegistry` directly. That was scheduler glue,
not the pure-data routing table the bindings duplicate. The native gap the node
fills is a *library* router a single-threaded embedder can drive, which never
existed: and which the conformance peer itself now drives, through
`driver.core.Host` (see the last consequence).

Engages the [First Principles](../../../AGENTS.md#first-principles): _protocol
correctness before implementation convenience_ (the router is protocol routing,
not language idiom) and _the portable core stays sync and no-I/O_ (the node owns
routing decisions but never a socket). _Conformance is load-bearing_: the live
`goblins-handoff` / `*-goblins-gift` matrix and the OCapN suite exercise this
seam in every role.

## Decision

A new `engine.Node` (`src/ocapn/engine/node.zig`; at acceptance also re-exported
as `driver.Node`, since deleted. ADR-0079) owns the router. It lives in the
engine core rather than the driver because it is
pure routing data: it touches only `foundation`/`model`/`engine`, never a
socket: so the sans-io `libpancake_ocapn` archive can project it without
depending on the I/O-bearing driver, and a native sans-io caller reaches it
without one. It holds a
connection table keyed by an integer `conn_id`, one node-owned `engine.Peer` per
registered connection, the retained node `seed`, one shared
`engine.bootstrap.GiftRegistry`, and the `redeemed` / `foreign_homes` tables,
every route value an integer `conn_id` or owned bytes, so the table is pure
data. The binding registers a connection (`registerConn`), which returns a
`conn_id` and the node-owned peer; the binding pumps that peer over its own
socket with the existing per-connection peer surface (`pancake_peer_*` /
`net.Connection`), so the node adds no second framing path. The router layers on
top: it mints the recipient withdraw (`sendWithdraw`), enrolls a redeemed cap
under a token (`enrollRedeemed`), resolves a send to a redeemed token's exporter
or a foreign home (`routeReference` / `foreignHome`) before the binding addresses
it, and records a fetched import's home (`recordForeignHome`).

The node is **sans-io**: it owns no sockets and no event loop. When redeeming a
give requires a connection to an exporter the node has not yet dialed, the
binding sees the give resolution, dials the exporter, and calls `registerConn` +
`sendWithdraw`; the binding keeps its own sockets and native async loop. This
preserves the core boundary (adapters own host integration) while the routing
*decision* lives once, in Zig.

The router was projected through the C ABI as pancake_node_* in
`libpancake_ocapn` at acceptance ([ADR-0059](ADR-0059-composable-c-abi-archives.md);
that C waist is deleted: see banner). The
router is removed from each binding `Machine`: the redeemed-token table, the
foreign-home table, the `next_token` counter, the retained-identity authority,
and the then-shared gift registry sink into the node. ADR-0100 later moves that
registry into each Peer. What survives binding-side is a
thin `Machine` over a node handle: host-idiom residue the sans-io core cannot
hold: the dialed-exporter cache (I/O lifetime), the `conn_id`-to-command-channel map
(how the host reaches the task that pumps a connection), the giftable factories
(vat-side host behaviors), and the redeem-reachability posture (a binding
policy). Each connection sources its node-owned peer from `register_conn` (a
non-owning peer wrapper the node frees), pumps it, and runs its vat addressed by
`conn_id`. Python and TypeScript drop their `Ref.home` field for the token model
(a redeemed cap is a synthetic far id `>= 2^60`, disjoint from any wire import,
routed by the node), which is the precondition that makes every route pure data.

The vat stays in the binding. This is the recorded boundary, on mechanism, not
doctrine:

- **Local turns stay FFI-free.** Intra-vat traffic (one host actor sending to
  another in the same vat) costs zero boundary crossings today. Sinking the turn
  queue and dispatch into Zig would make every local send a downcall to queue
  plus an upcall to run the target. The in-host vat buys free local turns; the
  router buys nothing by being duplicated.
- **Async behaviors suspend in the host.** A far promise resolving wakes a
  native continuation, and an `async` behavior that suspends mid-turn needs a
  per-runtime suspend/resume bridge that cannot leave the host. `Turn`
  (`src/actors/vat.zig`) is a re-entrant per-turn surface.

So routing sinks; the vat does not.

## Scope (what this does not decide)

- The handoff wire shapes, the signing contract, and the gift-registry authority
  are unchanged ([ADR-0009](ADR-0009-three-party-handoff-substrate.md),
  [ADR-0056](ADR-0056-vat-scoped-gift-registry.md) stand).
- The deeper sink: moving the whole vat machinery into Zig and reducing each
  binding to a dispatch shim: is **not** taken. It is fully featured but taxes
  local turns and needs a cross-FFI async suspend/resume bridge whose payoff is
  workload-dependent and unproven; it is left to a future measured spike, not
  built here.
- The completion, iroh, and WebRTC loop-hosts are not wired *under* the sans-io
  `engine.Node`. The scale path sits beside it: `driver.Bridge` over
  `completion.Loop`
  ([ADR-0057](ADR-0057-iroh-completion-loop-bridge.md) owns the loop-host;
  ADR-0089 covers WebRTC).
- The per-connection `engine.Peer` and the `pancake_peer_*` ABI stay as the
  single-connection primitive; the node is a tier above, so a one-connection
  client pays no node tax.

## Alternatives Considered

- **Keep the router in each binding.** Rejected: a routing decision copied four
  times in two designs is a latent inconsistency that must be fixed N times, and
  it leaves native Zig unable to do what every binding can.
- **Sink the vat too (the dispatch-shim node).** Rejected for this change: it
  relocates per-runtime host-scheduler glue into a re-entrant C-callback runtime
  and taxes FFI-free local turns, for a dedup win whose value is unproven. It is
  recorded as a future spike, not a present design.
- **An I/O-owning node (sockets inside Zig).** Rejected: it would push a
  scheduler and transports into a layer the architecture keeps sans-io, and
  fight every binding's native async runtime. The node surfaces I/O *needs* as
  events; the adapter owns the socket.

## Consequences

- `src/ocapn/engine/node.zig` owns the router; `engine/mod.zig` exports `Node` /
  `ConnId` (at acceptance `src/driver/mod.zig` also re-exported them; that
  `driver.Node` re-export is deleted. ADR-0079).
- `interop/goblins_interop/handoff_driver.zig` rebuilds its hand-rolled
  recipient redeem on `engine.Node` (the node mints the withdraw, enrolls the
  redeemed greeter under a token, and routes the call back to the exporter),
  making the router its own oracle against live Goblins (`goblins-handoff`) and
  closing the native-Zig gap.
- `conformance/ocapn-conformance/pancake_peer.zig` has since moved *onto* the
  node: it drives one `driver.core.Host` (which owns the node router) behind a
  `driver.Bridge` over a single completion loop. The original objection (a
  threaded oracle would push locking into the sans-io node, or wrap every node
  call in the peer's mutex) dissolved when the peer stopped being threaded: the
  one loop thread serializes every node call with no lock, and the Host settles a
  cross-session parked `withdraw-gift` itself (ADR-0056). The oracle keeps its
  independence because `driver.core.Host` is the ordinary product surface, not a
  conformance-only shim; the suite exercising the same host every embedder uses
  is stronger evidence than a bespoke harness above the node was.
- At acceptance, `src/c_abi/ocapn/node.zig` projected pancake_node_* into the
  *same* `libpancake_ocapn` archive and header as `pancake_peer_*` (one family,
  ADR-0059). That C waist is deleted; CapTP multi-connection product work uses
  `pancake_host_*` only (see banner).
- Each binding's router and route tables sink into the node; the surviving
  `Machine` is a thin node handle plus host-idiom residue (exporter cache,
  `conn_id`-to-channel map, giftable factories, reachability), and each connection
  sources its node-owned peer from `register_conn` and runs its vat over a
  `conn_id`. The Rust binding is migrated (`bindings/rust/src/session.rs`,
  with a non-owning `Peer::from_node_raw` in `bindings/rust/src/lib.rs`); the
  Python binding is migrated (`bindings/python/pancake/__init__.py`: a
  `NodeHandle` over pancake_node_*, a non-owning `Peer.from_node_raw`, and
  `Ref.home` dropped for the token model: and `bindings/python/pancake/iroh.py`);
  the TypeScript binding is migrated (`bindings/ts/stack/mod.ts`: a `NodeHandle`,
  a non-owning `Peer.fromNodeRaw`, and `Ref.home` dropped: and
  `bindings/ts/iroh/mod.ts`); the Racket binding is migrated
  (`bindings/racket/pancake.rkt`: a `node-handle` over pancake_node_*, a
  non-owning `peer/from-node-raw`, the in-binding `redeemed` / `next-token` /
  `fetched-homes` / shared-`gift-registry` tables replaced by node routing, and
  each `connection` keyed by a node `conn-id`: and `bindings/racket/pancake-iroh.rkt`).
  Every binding is now on the node. (Later vocabulary: that binding handle is
  `Host`, not `Node`. ADR-0079.)
- The live `goblins-handoff` / `*-goblins-gift` / `*-iroh-handoff` matrix and the
  OCapN suite gate every phase; the change lands phase by phase, never big-bang.
  The Rust, Python, Deno/TypeScript, and Racket phases are all green across their
  `*-goblins-handoff` / `*-goblins-gift` / `-interop` gates (Python and Racket also
  `*-iroh-handoff` / `-redeem-posture` / `-iroh-loop`; TypeScript also
  `deno-gifter-handoff` and `demo-rooms-dm-iroh`).

### Follow-on: node-unify-and-sink (historical)

The migration above left the binding handle named `Machine` with a separate
`NodeHandle` carrier over pancake_node_*, and it sank only the recipient-redeem
tables. A follow-on pass closed the remaining gaps; this section records that
intermediate shape (binding handle named `Node`), later superseded by ADR-0079’s
binding `Host`. Read “binding `Node`” below as that historical handle, not the
current public binding surface.

- **The binding handle was `Node`, the FFI carrier folded in.** Each binding's
  per-runtime endpoint was renamed `Machine` to `Node` (matching the core's
  `engine.Node` vocabulary of the day), and the former `NodeHandle` raw-pointer
  wrapper folded into it as a private carrier (`NodeRaw` / `_NodeRaw`). That
  binding handle is now `Host` (ADR-0079); "`engine.Node`" remains the sans-io
  router Host owns.
- **The gifter origination recipe is sunk too.** Beyond the recipient withdraw
  (`pancake_peer_send_withdraw_gift`), the gifter side is now one core call,
  `engine.Node.originateGive` (at acceptance also projected through the
  pancake_node_* serve step; CapTP product work uses `pancake_host_*`):
  it deposits the gift on the exporter, builds the signed `desc:handoff-give`, and
  queues its resolution on the recipient. Each binding's origination interceptor
  shrinks to that call plus its own flush; the duplicated build-and-sign glue is
  deleted. Native proof is hermetic (`test/engine/node_test.zig`) plus the live
  `*-goblins-gift` matrix and the native `demo-rooms-dm`.
- **The send-argument routability guard is one predicate.** Refusing to pass a
  capability that lives on another connection as a `send`/`tell` argument is the
  node's verdict, `engine.Node.argIsForeign` (at acceptance also
  pancake_node_arg_is_foreign): it folds the redeemed-token range and the
  foreign-home lookup into one call each binding makes, so the four bindings'
  fail-closed guards are one semantics, not four hand-rolled copies of the rule.
  `test/engine/node_test.zig` asserts that predicate directly.
- **The dial-posture rule deliberately stays binding-side.** It was *not* sunk:
  `Reachability` is iroh-transport vocabulary, kept out of the sans-io
  `libpancake_ocapn` core (ADR-0055), and the rule reduces to "when the locator
  carries direct-address hints, use `Direct`; otherwise use the node's configured
  redeem posture": transport idiom over the already-shared locator grammar, not a protocol
  decision. A core helper returning a posture code would leak iroh semantics into
  the core and thicken bindings to remove a one-line ternary; a second
  reachability transport would reuse the locator fact and supply its own posture
  enum locally. The node already carries the configured posture as an opaque int
  it never interprets.
- **One eventual-result and vat-ref vocabulary.** The bindings unify the public
  eventual-result type on `Vow` (Rust's `Promise` renamed; Python/TS/Racket
  already there) and the vat-internal reference on `VatRef`, distinct from the
  application capability `Ref` (Python's overloaded `Ref` split; Rust's
  `actors::Ref` alias dropped). `RemotePromise` (the pipelined handle) and the
  wire `Reference` variants are unchanged.

## Notes

Builds on [ADR-0100](ADR-0100-session-owned-handoff-authority.md) (the
session-owned gift authority the node's live-session directory resolves) and
[ADR-0053](ADR-0053-blocking-pump-single-fiber.md) (the per-connection blocking
pump the node multiplexes over).
