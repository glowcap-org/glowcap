---
id: ADR-0255
status: accepted
date: 2026-10-18
tags: [session, engine, node]
decision: "A promise the Node introduces to a recipient is a local promise projection on that session: a promise export whose row backs an inbound answer. The home promise's settlement settles that answer through the one outbound settlement spine as a guaranteed settlement, which stores under pressure and queues its carrier on a later step. A partner's desc:export listen joins the answer's listeners. No import row, listen cell, or relay-only settlement path exists."
supersedes: []
superseded_by: []
amends: [ADR-0095, ADR-0146, ADR-0194]
amended_by: []
---

# ADR-0255 A relayed promise is a projection on the recipient session

## Context

When a home session's promise is sent to another session, the Node gives the
recipient a promise of its own and settles it when the home promise settles
([ADR-0009](ADR-0009-three-party-handoff-substrate.md)). The recipient's half
was a third-party import row: an imported promise carrying a host, a listen
cell with its own listener list and stored resolution, and a relay-only
outbound path with its own fire preparation, retry counter, and stamp check.
The same session already owned a settlement mechanism for a promise it
settles: an inbound answer with its payload, listeners, consequence drain,
and carrier. One fact had two authorities, and the second one duplicated the
first's tables and pressure handling. [ADR-0254](ADR-0254-an-own-side-position-is-a-row-that-holds-its-facts.md)
made an own-side export a row that holds its facts, and a local promise
projection, an export whose row backs a virtual inbound answer, is exactly the
shape the recipient half needs.

## Decision

The Node's recipient promise is a local promise projection on the recipient
session (`src/ocapn/session/local_promise.zig`): `allocate` mints the promise
export and its backing answer in one dispatch, `abandon` rolls both back, and
the projection's payload exists from admission. The home promise's settlement
settles that answer through `Peer.settleAnswerTargetGuaranteed`
(`src/ocapn/engine/outbound.zig`), the ordinary answer settlement spine under
a guaranteed admission: the value is lowered, shortened, and stored as any
sent settlement is, and when outbound pressure refuses the carrier the row
keeps the stored value, roots itself, and the Peer queues the carrier on a
later step (`retryDeferredSettlement`). A partner's `desc:export` listen on
the projected promise installs on the backing answer and fires from the same
drain as every other listener. The Node's recipient row holds the peer, the
export, the answer target with its stamp, and the escrowed break
(`src/ocapn/engine/node/proxies/topology.zig`). A settlement whose target the
session no longer holds under that stamp is moot and releases its escrow
(`src/ocapn/engine/node/proxies/settlement.zig`). A staged settlement that
fails before commit spends its escrow from the batch itself
(`Batch.failure_escrow` in `src/ocapn/engine/node/passable/batches.zig`), so
the recipient breaks instead of hanging.

## Scope (what this does not decide)

A Host projection on a served answer keeps its failure action, because its
failure recipient is the embedder, not the Node. A projected promise has no
shortening subscription of its own across sessions. A projection settlement
on a session that is still negotiating stores, because the store is local
state, and only a closed session refuses it.

## Alternatives Considered

- **Keep the import row and listen cell beside the answer store.** Rejected
  because it is a second authority for one settlement, with its own listener
  table, retry counter, and pressure policy.
- **Root a collected projection through the recipient row so a withdraw never
  misses.** Rejected because a projection nobody holds is garbage, and a moot
  settlement that releases its escrow is the cheaper rule.
- **Project with a wire answer instead of an export.** Rejected because the
  recipient received a reference and listens on it with `desc:export`, as
  CapTP's recipient does.

## Consequences

`ImportedPromise` keeps only its row identity and shortening facts. The
pipeline listener classifier has no third-party class, and the engine has no
relay-only outbound path. The settlement spine gains the guaranteed admission
and the deferred-settlement count, and a deferred row is a collection root
until its carrier is queued. The Node's withdraw abandons only the pending
projection it admitted, still under the admitted stamp. A break under
allocation pressure stores without allocating, because the projection's
payload was created at admission.

## Evidence and gate

`test/engine/relay_resolution_test.zig` holds the guaranteed settlement
units: deferral under pressure, resolve-once, the `desc:export` listen, and
the stale stamp. `test/engine/node/proxy/` and
`test/engine/node/relay_failure_test.zig` hold the Node's recipient lifecycle,
including the escrowed break under allocation failure, and
`test/driver/core_host/pressure_test.zig` the deferred carrier under a Host.
`tools/check/source_check/c_abi/wiring.zig` holds the settlement entry
points. The gate is `zig build test -Dtest-layer=session,engine,driver`.

## Notes

[ADR-0009](ADR-0009-three-party-handoff-substrate.md) described the import
row shape this replaces. [ADR-0095](ADR-0095-listening-on-a-received-promise.md)
owns the listen verb, and [ADR-0254](ADR-0254-an-own-side-position-is-a-row-that-holds-its-facts.md)
the row model the projection is built on.
