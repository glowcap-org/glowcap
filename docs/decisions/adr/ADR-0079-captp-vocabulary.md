---
id: ADR-0079
status: accepted
date: 2026-07-12
tags: [vocabulary, driver, bindings, c-abi, captp]
decision: "CapTP vocabulary is one sticky note across Zig, C, and bindings: Host is the multi-session CapTP product (owns engine.Node). engine.Node is the sans-io handoff router (router half of Goblins mycapn). Session is the CapTP one-partner app object (driver.Session / binding Session). BlockingSession is Served + net.Connection with a blocking pump (formerly ConnectedVat). driver_core.HostSession / GlowcapHostSession is the host-registered shell. net.Connection is the framed byte stream only. HostedActor / spawnHosted is embedder-hosted behavior (formerly ForeignActor / spawnForeign). DialResolver replaces transport Locator. ContextAllocator replaces HostAllocator. Goblins mycapn combines product and router roles. It is never a single-type equation. The old application-level binding Node and Connection names are deleted. driver.Node re-export is deleted."
supersedes: []
superseded_by: []
amends: [ADR-0066, ADR-0067, ADR-0069]
amended_by: [ADR-0109, ADR-0113]
---

# ADR-0079 CapTP vocabulary. Host, Node, Session, sticky note

## Context

Several CapTP names taught the wrong layer. Bindings exported `Node` for
`GlowcapHost`, equating that product with Goblins `mycapn` and with
`engine.Node`, and called the CapTP partner `Connection` while Zig spoke
`driver.Session` (`d31309cc9` Session/Conn/Slot). Transport dial helpers shared
the noun `Locator` with OCapN `PeerLocator`. Embedder allocation was
`HostAllocator` next to CapTP `Host`. `ConnectedVat` named a Vat when the type
is a blocking session over a stream. `ForeignActor` collided with ADR-0069
foreign-import vocabulary.

ADR-0066's follow-on that equated binding `Node` with `engine.Node` is amended.
Its router decision stands.

## Decision

**Sticky note (survivors):**

| Name | Role |
|------|------|
| `Host` / `GlowcapHost` / binding `Host` | Multi-session CapTP product |
| `engine.Node` | Sans-io handoff router Host owns |
| `Session` (`driver.Session`, binding `Session`) | CapTP one-partner app object |
| `BlockingSession` | `Served` + `net.Connection`, blocking pump |
| `driver_core.HostSession` / `GlowcapHostSession` | Host-registered partner shell |
| `net.Connection` | Framed byte stream |
| `ocapn/session.Session` | Protocol table authority (module-qualified) |
| `HostedActor` / `spawnHosted` | Embedder-hosted behavior |
| `DialResolver` | Transport dial resolve (was `tcp`/`iroh` `Locator`) |
| `ContextAllocator` | Embedder allocator for `GlowcapContext` |

**mycapn (two roles):** its product role maps to `Host`. Its router tables map
to `engine.Node`. No single type equals `mycapn`.

**Internal-vocabulary rule:** `conn`/`connection` names only a byte stream. `net.Connection`, and the transport handles `GlowcapTcpConn`,
`GlowcapInprocConn`, `GlowcapIrohConn`. A CapTP conversation with one partner is
a `session` everywhere above `engine.Peer`: type names, fields, params, and C
symbols alike. A per-partner session named `Conn` / `GlowcapHostConn` would collide with the
byte-stream `Conn` in the same C ABI, so the driver family is
`GlowcapHostSession` / `glowcap_host_session_*` and `driver_core.HostSession`.
`checkCaptpVocabulary` in `tools/check/source_check.zig` holds the rule.

**`endpoint`:** the transport-bound local identity (an iroh endpoint, a
netlayer's bound address). It is a transport concept and not a `Host` synonym.
`Host` is the CapTP product.

**Deletes / renames:** application-level binding `Node` becomes `Host` and
application-level binding `Connection` becomes `Session`. `ConnectedVat`
becomes `BlockingSession`. `ForeignActor` becomes `HostedActor`. `spawnForeign` becomes `spawnHosted`. Delete
`Served.bindForeign` (use `bindExport`). Delete `driver.Node` re-export.
`HostAllocator` becomes `ContextAllocator`. Transport `Locator` becomes
`DialResolver`.

**Rejected:** renaming `engine.Node` to `Router`. Reverting `driver.Session` to
`Connection`. Renaming `net.Connection` to `Stream` to free the word. Bimodal
owning/borrowing Session.

## Consequences

- Living-state docs and `tools/check/source_check.zig` ban the retired names.
- Read ADR-0066's binding `Node` as `Host`.

### Held decisions

| Item | Held decision |
|------|----------------|
| Dual `HostAction` / `Node.Action` queue | **Reject merge.** Two contracts, different lifetimes (`docs/boundaries.md`). Both use `engine.ActionFifo`. Projection is the lifetime boundary. |
| `Session` ⊃ `BlockingSession` | **Keep.** Owning Session embeds BlockingSession. No mode flag. Shared verbs via forwarders are ownership tiers (ADR-0062). |
| Internal shell vs `GlowcapHostSession` | **Keep `HostSession`.** `driver_core.HostSession` and `GlowcapHostSession` are the host-registered shell. `Session` is the application-facing CapTP partner object. `Conn` remains reserved for byte connections. |
| C `glowcap_designator_host_port` | **Keep.** C “host” means TCP hostname in the designator grammar. Bindings use `hostname`/`bindHost` at CapTP-product collision sites. |
| `Served` prominence | **Keep.** Unique sans-io serve core. Interior of `BlockingSession` / `HostSession`, not an app peer of `Session`. |
| `engine.Peer` glossary | **Keep.** Established glowcap vocabulary for the local CapTP session engine. CapTP prose “peer” for the remote party stays in docs, not the type name. |
| CapTP Frontend/Backend seating | **HostedActor / spawnHosted is the seating.** Do not invent a CapTP `Backend` type (clashes with `completion.Backend`). Qualify I/O as `completion.Backend` in cross-layer prose. |
