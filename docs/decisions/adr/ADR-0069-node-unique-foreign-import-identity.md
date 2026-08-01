---
id: ADR-0069
status: accepted
date: 2026-07-07
tags: [engine, node, handoff, three-party, routing, gc, api]
decision: "A fetched foreign capability is identified across connections by a node-unique token, not by its wire import position. `engine.Node` enrolls every fetched far import under a token drawn from the same reserved high range as a redeemed handoff token, mapping it to a `Route{home_conn, real_wire_reference}`, and hands the application that token; routing, the gifter-side origination interceptor, and the send-argument foreign verdict all resolve through the enrollment instead of through the old position-keyed `foreign_homes` map. This closes a real cross-connection identity collision (import positions are per-session, so two capabilities fetched over different connections routinely share a position, and the node-global position key made the second fetch clobber the first, mis-routing every introduction after the first to the last-fetched exporter (revealed by the rooms directory, which introduces many members over one identity). The enrollment is also swept in `removeConn`, fixing a companion leak. A single outbound chokepoint (`Peer.send` calling `Node.lowerForConn`) lowers every reference in an outbound message, so a token cannot leak in any emission position. The native Zig driver adopts the token first, proven by a two-exporter handoff test; at acceptance the C ABI surfaced the enrollment as pancake_node_enroll_foreign (that C waist is deleted) CapTP product work uses `pancake_host_*`) and all four bindings adopt it, the TypeScript one proven by the rooms direct-message reproduction; the deprecated position-keyed path and the old record-foreign-home helper are then removed, leaving the token as the node's one foreign-capability identity."
supersedes: []
superseded_by: []
amends: []
amended_by: [ADR-0079, ADR-0096]
---

# ADR-0069 A fetched foreign capability is identified by a node-unique token

> **C-projection / vocabulary amendment (ADR-0079).** The Zig `engine.Node`
> token enrollment and its semantics remain accepted. The former
> pancake_node_enroll_foreign C entry (and the pancake_node_* waist) were
> deleted; CapTP multi-connection product work uses `pancake_host_*`. Binding
> `Node` is not the current multi-conn product: that is binding `Host`. Read
> historical pancake_node_* / binding-`Node` mentions below as acceptance-time
> shape.

## Context

`engine.Node` (ADR-0066) makes a three-party handoff transparent. When a served
reply returns a capability the node fetched from another connection, the node's
resolve interceptor recognizes it as *foreign* and originates the gifter half of
a handoff instead of encoding a cross-connection reference. It recognizes the
capability by looking it up in `foreign_homes`, a map from the capability's far
import position to the connection it lives on, written by `recordForeignHome`
after every `fetch`.

That key is wrong. An import position is a **per-session** name: CapTP numbers
imports per connection, each starting fresh, so the same position value occurs on
every connection. A single node that holds fetched capabilities from more than
one connection therefore has more than one capability at the same position, and
the node-global `foreign_homes[position] = home` makes the second `fetch` clobber
the first. Every later re-gift then resolves to the last-fetched home. A broker
that introduces a *single* exporter never trips it: which is why every existing
handoff demo and test passed: but a broker that introduces *several* parties
mis-routes all but the last introduction back to that last party.

The rooms directory is exactly such a broker: each browser tab is a member it
fetches a `dm` inbox from, and it introduces members to each other. With two
members, introducing the first resolves to the second, so a direct message loops
back to the sender. Rooms revealed the defect; it is general, and it is the only
instance of its class in the tree (every other cross-connection table keys on a
node-unique token, a `ConnId`, a `conn_id`-composite key, or a global crypto or
locator identity).

A composite key `{conn_id, import_position}` does not fix it: at the point the
node must find the home (the interceptor, resolving a reply on the *recipient's*
connection), the node has the recipient connection and the position but not the
home connection: the home is precisely what it is looking up. The far reference
the application hands back is `far(position)`, and two such references are
byte-identical. The only sound fix is to make the application-held identity
node-unique.

`foreign_homes` is also never reclaimed in `removeConn` (which sweeps every other
per-connection table), so it both leaks and, with stale rows from closed
connections colliding against live low positions, sharpens the mis-routing.

## Decision

A fetched foreign capability is identified by a **node-unique token**, the same
device the node already uses for a redeemed handoff capability (ADR-0066's
reserved high range, disjoint from any wire import position). `fetch` no longer
hands the application the raw `far(position)`; the node enrolls the import under a
token and hands back `far(token)`. The enrollment records a
`Route{home_conn, real_wire_reference}`: the connection the capability lives on
and the real `far(position)` to address there.

A token is a node-local id and must never reach the wire. Rather than swap it to
its wire form at each of the several places a reference is emitted: a send
target, a forwarded target, an argument, a resolution: the peer lowers every
reference in an outbound message at the one place all outbound messages funnel
through: `Peer.send` (via `enqueueRecorded`), calling `Node.lowerForConn` through
a hook the node installs on each registered peer. A reference below the reserved
range is returned untouched (the fast path, every real wire reference), and the
walk runs only after the node has enrolled its first foreign token, so a two-party
peer pays nothing. This is the structural guarantee: a token cannot leak in a
position someone forgot to patch, because there is one lowering site and it is on
the encode path itself. A token whose home is another connection has no wire name
there and fails **closed** with `TokenNotLiftable`, turning a routing bug into a
loud error instead of a synthetic id on the wire.

Two decisions remain above the chokepoint, because only they choose a *different*
connection than the one the application addressed:

- **Routing a send target across connections** (`routeReference`/`route`): a
  `far(token)` addressed from a connection other than its home redirects to its
  `home_conn` with the real `far(position)`: the same redirect a redeemed token
  gets. The driver does this before `send`; the chokepoint then lowers a token
  addressed on its own home.
- **Re-gifting a served reply** (the host's resolve interceptor over
  `interceptFulfilledRef`): when a returned capability's home is *another*
  connection, the node re-gifts it: depositing the **real** `far(position)` on
  that home and building the give toward it (depositing the token would name an
  export the exporter never made). When the home is *this* connection the
  interceptor returns the reference unchanged and the chokepoint lowers it. The
  interceptor's `?Argument` return distinguishes a claimed re-gift (null) from an
  ordinary pass-through, nothing more.

The send-argument foreign verdict (`argIsForeign`) stays as the binding's early,
descriptive check: a `far(token)` is foreign exactly when its enrolled home is not
the connection being addressed. It no longer has to be the last line of defense,
the chokepoint fails an off-home token closed regardless: but a binding may still
consult it to reject a cross-connection argument with a clearer error before the
send.

The enrollment is swept in `removeConn` when its home closes, bounding a
long-running broker's routing rows. A token whose enrollment has been reclaimed
(or a redeemed token whose exporter is gone) routes nowhere, and `routeReference`
then fails it **closed** rather than passing the synthetic id through: a
reference in the reserved range that routes nowhere is a retired token, never a
wire import.

### Interactions

- **Garbage collection (ADR-0063).** A binding releases a fetched import by its
  wire position (`op:gc-exports`). Because the application now holds the token,
  the release path translates the token back to its `{home_conn, position}`
  before emitting the delta. The native driver does not garbage-collect fetched
  imports, so this concerns only the language bindings.
- **The gifter identity is unchanged.** The gift is still signed by the node
  seed; only the internal routing key changes. Deposit/withdraw verification is
  untouched.
- **Same-home arguments and resolutions are lowered.** Because the chokepoint
  lowers *every* reference an outbound message carries, a fetched capability passed
  as a send argument, or used to fulfill a resolution, on its own home connection
  now reaches the wire as its real import, not only send targets and served
  replies. A token addressed *across* connections in argument position still has
  no wire name and fails closed; cross-connection argument origination (a re-gift
  from argument position, rather than reply position) remains the one boundary
  ADR-0066 draws, unchanged by this ADR.

### Migration

The change spans the whole stack, because a fetched capability's identity is held
by every consumer. It lands in stages so each is provable on its own:

1. The `Node` gains the token enrollment; the native Zig driver adopts it at
   `fetch`. The position-keyed `foreign_homes` path is retained, unused by the
   driver, so the C ABI and the four language bindings keep compiling and their
   single-exporter dogfoods keep passing while they still use it. A two-exporter
   handoff test (`test/driver/`) proves the driver routes each introduction to
   its own exporter: the test that fails under the old key and passes under the
   new one.
2. The outbound chokepoint (`Peer.send` to `Node.lowerForConn`) lowers tokens
   uniformly, so the token model no longer leaks in any emission position: the
   prerequisite for a binding to hold tokens without a per-path lowering rule of
   its own.
3. At acceptance the C ABI surfaced the enrollment (pancake_node_enroll_foreign;
   that entry is gone with the pancake_node_* waist: see banner), and every
   language binding adopts the token at `fetch` (and `enliven`, where it records a
   home), translating it back to its wire position in the GC path. The TypeScript
   (Deno, Bun), Python, Rust, and Racket bindings are all migrated; the TypeScript
   one is proven by the rooms direct-message reproduction that mis-routed under the
   position key and routes correctly under the token. With the last binding
   migrated, the position-keyed `foreign_homes` map and
   the old record-foreign-home helper are removed, so the token enrollment is the
   node's one foreign-capability identity.

## Consequences

- The cross-connection identity collision is closed at the root, in one place,
  for every consumer: the native driver and all four bindings hold a fetched
  capability's identity as a token, not worked around per application.
- The `Node` carries one foreign-capability table, the token enrollment. The
  deprecated position-keyed map and its C ABI entry point are gone, so there is no
  second identity for a fetched capability to drift against.
- `removeConn` reclaims the enrollment, so a long-running broker (a directory
  serving members that come and go) no longer accumulates stale routing rows.
- The token model is now the single identity for *both* halves of a handoff,
  the redeemed capability a recipient holds and the fetched capability a gifter
  re-gifts: which is the shape ADR-0066 was reaching for when it retired the
  per-binding `Ref.home` field.
