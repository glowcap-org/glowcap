---
id: ADR-0079
status: accepted
date: 2026-07-12
tags: [vocabulary, driver, bindings, c-abi, captp]
decision: "CapTP vocabulary is one sticky note across Zig, C, and bindings: Host is the multi-session CapTP product (owns engine.Node); engine.Node is the sans-io handoff router (router half of Goblins mycapn); Session is the CapTP one-partner app object (driver.Session / binding Session); BlockingSession is Served + net.Connection with a blocking pump (formerly ConnectedVat); driver_core.HostSession / PancakeHostSession is the host-registered shell; net.Connection is the framed byte stream only; HostedActor / spawnHosted is embedder-hosted behavior (formerly ForeignActor / spawnForeign); DialResolver replaces transport Locator; ContextAllocator replaces HostAllocator. Goblins mycapn combines product and router roles; it is never a single-type equation. The old application-level binding Node and Connection names are deleted. driver.Node re-export is deleted."
supersedes: []
superseded_by: []
amends: [ADR-0066, ADR-0067, ADR-0069]
amended_by: [ADR-0109, ADR-0113]
---

# ADR-0079 CapTP vocabulary. Host, Node, Session, sticky note

## Context

Several CapTP names taught the wrong layer: bindings exported `Node` for
`PancakeHost`, equated that product with Goblins `mycapn` and with
`engine.Node`, and called the CapTP partner `Connection` while Zig already
spoke `driver.Session` (`7e27c1d` Session/Conn/Slot). Transport dial helpers
shared the noun `Locator` with OCapN `PeerLocator`. Embedder allocation was
`HostAllocator` next to CapTP `Host`. `ConnectedVat` named a Vat when the type
is a blocking session over a stream. `ForeignActor` collided with ADR-0069
foreign-import vocabulary.

ADR-0066's follow-on that equated binding `Node` with `engine.Node` is amended
for living guidance; its router decision remains accepted.

## Decision

**Sticky note (survivors):**

| Name | Role |
|------|------|
| `Host` / `PancakeHost` / binding `Host` | Multi-session CapTP product |
| `engine.Node` | Sans-io handoff router Host owns |
| `Session` (`driver.Session`, binding `Session`) | CapTP one-partner app object |
| `BlockingSession` | `Served` + `net.Connection`, blocking pump |
| `driver_core.HostSession` / `PancakeHostSession` | Host-registered partner shell |
| `net.Connection` | Framed byte stream |
| `ocapn/session.Session` | Protocol table authority (module-qualified) |
| `HostedActor` / `spawnHosted` | Embedder-hosted behavior |
| `DialResolver` | Transport dial resolve (was `tcp`/`iroh` `Locator`) |
| `ContextAllocator` | Embedder allocator for `PancakeContext` |

**mycapn (two roles):** its product role maps to `Host`; its router tables map
to `engine.Node`. Never “X IS mycapn” as a single equation.

**Internal-vocabulary rule (amendment):** `conn`/`connection` names *only* a byte
stream. `net.Connection`, and the transport handles `PancakeTcpConn`,
`PancakeInprocConn`, `PancakeIrohConn`. A CapTP conversation with one partner is
a `session` everywhere above `engine.Peer`: type names, fields, params, and C
symbols alike. This is the rule the byte-fed host tier once broke by defining its
per-partner session `Conn` / `PancakeHostConn`, which collided with the
byte-stream `Conn` in the same C ABI: the old host-conn form even carried
both words in one symbol, a conn whose check verb read session-open. The driver
family is now `PancakeHostSession` /
`pancake_host_session_*` and `driver_core.HostSession`; `checkCaptpVocabulary` in
`tools/check/meta_check.zig` keeps the collision from returning.

**`endpoint`:** reserve it for the transport-bound local identity (an iroh
endpoint, a netlayer's bound address), not as a `Host` synonym. `endpoint` is a
transport concept; `Host` is the CapTP product.

**Deletes / renames:** application-level binding `Node` becomes `Host` and
application-level binding `Connection` becomes `Session`; `ConnectedVat` becomes `BlockingSession`; `ForeignActor`
becomes `HostedActor`; `spawnForeign` becomes `spawnHosted`; delete
`Served.bindForeign` (use `bindExport`); delete `driver.Node` re-export;
`HostAllocator` becomes `ContextAllocator`; transport `Locator` becomes
`DialResolver`.

**Rejected:** renaming `engine.Node` to `Router`; reverting `driver.Session` to
`Connection`; renaming `net.Connection` to `Stream` to free the word; bimodal
owning/borrowing Session.

## Consequences

- Living-state docs and `tools/check/meta_check.zig` ban resurrected lies.
- ADR-0066 binding-Node guidance is historical; read product as `Host`.

### Once-there holds (assessed after Phase A gated green)

| Item | Held decision |
|------|----------------|
| Dual `HostAction` / `Node.Action` queue | **Reject merge.** Two contracts, different lifetimes (`docs/boundaries.md`). Both use `engine.ActionFifo`; projection is the lifetime boundary. |
| `Session` ⊃ `BlockingSession` | **Keep.** Owning Session embeds BlockingSession; no mode flag. Shared verbs via forwarders are intentional ownership tiers (ADR-0062). |
| Internal shell vs `PancakeHostSession` | **Keep `HostSession`.** `driver_core.HostSession` and `PancakeHostSession` are the host-registered shell; `Session` is the application-facing CapTP partner object. `Conn` remains reserved for byte connections. |
| C `pancake_designator_host_port` | **Keep.** C “host” means TCP hostname in the designator grammar; bindings use `hostname`/`bindHost` at CapTP-product collision sites. |
| `Served` prominence | **Keep.** Unique sans-io serve core; interior of `BlockingSession` / `HostSession`, not an app peer of `Session`. |
| `engine.Peer` glossary | **Keep.** Established pancake vocabulary for the local CapTP session engine; CapTP prose “peer” for the remote party stays in docs, not the type name. |
| CapTP Frontend/Backend seating | **HostedActor / spawnHosted is the seating.** Do not invent a CapTP `Backend` type (clashes with `completion.Backend`). Qualify I/O as `completion.Backend` in cross-layer prose. |
