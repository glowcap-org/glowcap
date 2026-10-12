---
id: ADR-0066
status: accepted
date: 2026-06-19
tags: [driver, handoff, three-party, node, c-abi, bindings]
decision: "The cross-connection handoff router is sunk into a sans-io `engine.Node` in the Zig core (at acceptance also re-exported as `driver.Node` for native ergonomics, that re-export is deleted (ADR-0079): it owns the connection table keyed by integer `conn_id`, one node-owned `engine.Peer` per connection, the retained node `seed`, the shared `engine.bootstrap.gifts.GiftRegistry`, and the redeemed / foreign-home routing tables, and at acceptance was projected through the C ABI as glowcap_node_* in the sans-io `libglowcap_ocapn` (that C waist is deleted, CapTP multi-connection product work uses `glowcap_host_*` only). It lives in the engine core, not the I/O-bearing driver, because it is pure routing data and the sans-io archive must project it without dragging in a transport. The router is removed from each binding `Machine`) the duplicated protocol tables sink into the node: leaving a thin handle that holds only host-idiom residue (the dialed-exporter cache, the `conn_id`-to-command-channel map, the giftable factories, the redeem-reachability posture) over a vat addressed by `conn_id`. The vat (turn loop, promise resolution, await, behavior dispatch) stays in the binding. Only the router sinks."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0079, ADR-0100, ADR-0113, ADR-0116]
---

# ADR-0066 The cross-connection handoff router is a sans-io node

> ADR-0100 removed the shared `GiftRegistry` from Node. Node keeps the live
> session directory and authority-neutral dependencies keyed by
> `(Gifter–Exporter PeerHandle, fixed-size gift tag)`, so a deposit wakes only the
> receiver Peers parked on that exact gift. Each Peer owns its session's gifts,
> scalar replay counters, and exact-keyed pending groups.
>
> The glowcap_node_* C projection in `libglowcap_ocapn` was deleted. CapTP
> multi-session product work uses `glowcap_host_*` only. Per ADR-0079, the
> multi-session product is `Host` / `GlowcapHost` / binding `Host`,
> `engine.Node` is the router Host owns, and a binding's CapTP partner is
> `Session`. The `driver.Node` re-export is deleted. Where this record says
> "binding `Node`" or names the glowcap_node_* family, it describes the shape
> at acceptance.

## Context

The three-party handoff router (Goblins' `mycapn`, distinct from a per-partner
connection) existed four times, once in each binding's `Machine` (Rust
[`bindings/rust/src/session.rs`](../../../bindings/rust/src/session.rs) and its
Python/TypeScript/Racket peers), in two divergent designs, and nowhere in native
Zig. Each copy holds the same state:

- a retained node `seed` reused for every connection, so an exporter verifies a
  `desc:handoff-receive` against one key
- a `redeemed` map from a synthetic far token to the exporter connection that
  hosts it
- a `foreign_homes` map from a fetched import to its home connection, so a
  published actor returning a far cap from elsewhere re-gifts instead of
  mis-encoding a cross-connection reference
- the shared `engine.bootstrap.gifts.GiftRegistry`
  ([ADR-0056](ADR-0056-vat-scoped-gift-registry.md)) that lets a deposit on the
  gifter session meet a withdraw on the recipient session

The binding's `giftables` (a name-to-behavior-factory map republished on each
connection) are not part of the router: a factory mints a host behavior, so it
is vat-side and stays in the binding.

A protocol decision copied N times is a latent inconsistency, and the two
binding designs had drifted on the redeemed-token encoding. The router could not
sink because every route value pointed at a language connection object (a
`tokio` channel, an `asyncio` task). The native Zig `BlockingSession` had no
router.

The conformance host
([`conformance/ocapn-conformance/glowcap_peer.zig`](../../../conformance/ocapn-conformance/glowcap_peer.zig))
was not a fifth copy. Its `GifterHub` was host-thread scheduler glue that handed
gifter requests between per-connection threads under a mutex, while calling the
engine handoff primitives directly. The gap the node fills is a library router a
single-threaded embedder can drive, which the conformance peer now uses through
`driver.core.Host`.

The live `goblins-handoff` and `*-goblins-gift` matrix and the OCapN suite
exercise this seam in every role.

## Decision

`engine.Node` (`src/ocapn/engine/node.zig`) owns the router. It lives in the
engine core, not the driver, because it is pure routing data: it touches only
`foundation`/`model`/`engine` and never a socket, so the sans-io archive could
project it and a native sans-io caller reaches it without the I/O-bearing
driver. It holds a connection table keyed by an integer `conn_id`, one
node-owned `engine.Peer` per registered connection, the retained node `seed`,
and the `redeemed` / `foreign_homes` tables. Every route value is an integer
`conn_id` or owned bytes.

The embedder registers a connection (`registerConn`), which returns a `conn_id`
and the node-owned peer, and pumps that peer over its own socket with the
per-connection peer surface (`net.Connection`), so the node adds no second
framing path. The router layers on top. It mints the recipient withdraw
(`sendWithdraw`), enrolls a redeemed cap under a route id (`enrollRedeemed`),
resolves a send to that route's exporter or a foreign home (`routeReference` /
`foreignHome`) before the embedder addresses it, and records a fetched import's
home (`recordForeignHome`).

The node is sans-io: it owns no sockets and no event loop. When redeeming a give
requires a connection to an exporter the node has not dialed, the embedder sees
the give resolution, dials the exporter, and calls `registerConn` +
`sendWithdraw`. Adapters keep their sockets and async loop, and the routing
decision lives once, in Zig.

The gifter origination recipe is also one core call,
`engine.Node.provideGiftId`: it deposits the gift on the exporter, builds the
signed `desc:handoff-give`, and queues its resolution on the recipient. A
binding's origination interceptor is that call plus its own flush.
`engine.Node.argIsForeign` is the refusal authority for model-tier calls that
cannot transfer a Host capability retain. ADR-0116 routes owning binding values
through recursive inline handoff, so bindings do not duplicate or project this
predicate.

Each binding's router and route tables (the redeemed-token table, the
foreign-home table, the `next_route_id` counter, and the retained-identity
authority) sink into the node. What stays binding-side is host-idiom residue the
sans-io core cannot hold:

- the dialed-exporter cache (I/O lifetime)
- the `conn_id`-to-command-channel map (how the host reaches the task that pumps
  a connection)
- the giftable factories (vat-side host behaviors)
- the redeem-reachability posture (binding policy)

Each connection sources its node-owned peer from the node, pumps it, and runs its
vat addressed by `conn_id`. Python and TypeScript drop their `Ref.home` field for
the token model: a redeemed cap is an explicit node-local routed reference,
disjoint by type from every wire import, which makes every route pure data. All
four bindings are migrated.

The dial-posture rule stays binding-side. `Reachability` is iroh-transport
vocabulary kept out of the sans-io core (ADR-0055), and the rule reduces to
"when the locator carries direct-address hints, use `Direct`, otherwise use the
configured redeem posture". That is transport idiom over the shared locator
grammar, not a protocol decision, and a core helper returning a posture code
would leak iroh semantics into the core to remove a one-line ternary. The node
carries the configured posture as an opaque int it never interprets.

The bindings share one eventual-result and vat-ref vocabulary: the public
eventual result is `Vow`, and the vat-internal reference is `VatRef`, distinct
from the application capability `Ref`. `RemotePromise` (the pipelined handle) and
the wire `Reference` variants are unchanged.

### The vat stays in the binding

The boundary rests on mechanism:

- **Local turns stay FFI-free.** Intra-vat traffic (one host actor sending to
  another in the same vat) costs zero boundary crossings. Sinking the turn queue
  and dispatch into Zig would make every local send a downcall to queue plus an
  upcall to run the target. The router gains nothing by being duplicated.
- **Async behaviors suspend in the host.** A far promise resolving wakes a native
  continuation, and an `async` behavior that suspends mid-turn needs a
  per-runtime suspend/resume bridge that cannot leave the host. `Turn`
  (`src/actors/vat/mod.zig`) is a re-entrant per-turn surface.

Routing sinks and the vat does not.

## Scope (what this does not decide)

- The handoff wire shapes and the signing contract are unchanged
  ([ADR-0009](ADR-0009-three-party-handoff-substrate.md)).
- Moving the whole vat machinery into Zig and reducing each binding to a dispatch
  shim is not taken. It taxes local turns and needs a cross-FFI async
  suspend/resume bridge whose payoff is workload-dependent and unproven. It
  waits on a measured spike.
- The completion, iroh, and WebRTC loop-hosts are not wired under the sans-io
  `engine.Node`. The scale path sits beside it: `driver.Bridge` over
  `completion.Loop`
  ([ADR-0057](ADR-0057-iroh-completion-loop-bridge.md) owns the loop-host,
  ADR-0089 covers WebRTC).
- The per-connection `engine.Peer` stays the single-connection primitive. The
  node is a tier above, so a one-connection client pays no node tax.

## Alternatives Considered

- **Keep the router in each binding.** Rejected: a routing decision copied four
  times in two designs must be fixed N times, and native Zig could not do what
  every binding can.
- **Sink the vat too (the dispatch-shim node).** Rejected: it relocates
  per-runtime host-scheduler glue into a re-entrant C-callback runtime and taxes
  FFI-free local turns, for a dedup win whose value is unproven.
- **An I/O-owning node (sockets inside Zig).** Rejected: it would push a
  scheduler and transports into a layer the architecture keeps sans-io, and
  fight every binding's native async runtime. The node surfaces I/O needs as
  events, and the adapter owns the socket.

## Consequences

- `src/ocapn/engine/node.zig` owns the router. `engine/mod.zig` exports `Node` /
  `ConnId`.
- `interop/goblins_interop/handoff_driver.zig` builds its recipient redeem on
  `engine.Node` (the node mints the withdraw, enrolls the redeemed greeter under
  a token, and routes the call back to the exporter), so the router is checked
  against live Goblins (`goblins-handoff`) and native Zig has the capability.
- `conformance/ocapn-conformance/glowcap_peer.zig` drives one `driver.core.Host`
  (which owns the node router) behind a `driver.Bridge` over a single completion
  loop. The one loop thread serializes every node call with no lock, and the Host
  settles a cross-session parked `withdraw-gift` itself (ADR-0056). The suite
  exercises the same host every embedder uses, which is stronger evidence than a
  bespoke harness above the node.
- Native proof of origination is hermetic (`test/engine/node/`) plus the live
  `*-goblins-gift` matrix and the native `demo-rooms-dm`.
- The live `goblins-handoff` / `*-goblins-gift` / `*-iroh-handoff` matrix and the
  OCapN suite gate each binding: the `*-goblins-handoff`, `*-goblins-gift`, and
  `-interop` gates for Rust, Python, Deno/TypeScript, and Racket, plus
  `*-iroh-handoff`, `-redeem-posture`, and `-iroh-loop` where they apply
  (TypeScript also `deno-gifter-handoff` and `demo-rooms-dm-iroh`).

## Notes

Builds on [ADR-0100](ADR-0100-session-owned-handoff-authority.md) (the
session-owned gift authority the node's live-session directory resolves) and
[ADR-0053](ADR-0053-blocking-pump-single-fiber.md) (the per-connection blocking
pump the node multiplexes over).
