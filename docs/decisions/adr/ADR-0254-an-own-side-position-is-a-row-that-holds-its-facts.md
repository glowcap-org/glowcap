---
id: ADR-0254
status: accepted
date: 2026-10-18
tags: [session, engine, actors, driver]
decision: "A position this session mints indexes a dense slab, a released position is the next one minted, and a reader that outlives a turn names a question by its position and the stamp of its row. Every fact about such a position lives on its row: an outbound answer's row holds the resolver export that settles it, and an export's row holds its binding, its count, and what the export is for. No table keyed by an own-side position exists beside the rows. Positions the partner chooses stay hashed under the session secret."
supersedes: []
superseded_by: []
amends: [ADR-0095, ADR-0223, ADR-0224]
amended_by: []
---

# ADR-0254 An own-side position is a row that holds its facts

## Context

CapTP gives a session two kinds of position. Imports and inbound answers
are the partner's to choose, so their tables hash under the session's secret
multiplier (ADR-0223): an untrusted peer can name `1 << 63`, and a vector
would try to grow to it. Exports and outbound answers are this session's to
mint, in sequence from a base, and the same hashed tables held them, a
defense built for a chooser the session does not face.

The facts about one own-side position were spread over several of those
tables. An outbound answer had its row, and the resolver export that settles
it was in the outbound resolver link, a two-way map keyed by export position
whose reverse side, keyed by the purpose's words (ADR-0224), let the session
ask which export served an answer, a local promise, or a shortening source.
The inbound deliver route asked that map five questions in turn before
falling through to ordinary delivery, and every transition had to keep two
or three tables in step.

OCapN lets a position return: "Once the answer-pos has been GC'd through
sending op:gc-answers, the answer-pos can be re-used", and the same holds
for an export the partner released with `op:gc-exports`. The stream is
ordered, so nothing the partner sends after its release can mean the old
row. A position was never minted twice, and so every reader that outlived a
row (a queued resolve event, a vat listener, a Host vow, a node redeem
destination) kept the bare position as the question's identity.

## Decision

**A slab over own-side positions.** `session.PositionSlab(Row)`
(`src/ocapn/session/position_slab.zig`) is a vector indexed by position
with a doubly linked free list through its retired slots. `ExportTable`
(`export_table.zig`) indexes `position - base` and keeps the bootstrap
position as a flag beside the rows. `OutboundAnswerTable` indexes the
position itself. A freed slot is the next one minted. `reserve` grows the
vector by half plus one slot, and an explicit install grows it to the exact
index it names, so an explicit export position (`Peer.exportObject`) costs
the slots up to it, a cost its chooser pays.

**A stamped identity for a reader that outlives a turn.** A question's
identity is `OutboundAnswerTarget`: its position and the stamp of the row
minted for it (`Session.nextStoreStamp`), the shape `AnswerTarget` gives an
inbound answer and `PromiseIncarnation` an imported promise.
`OutboundAnswerTable.live` finds a row only under its own stamp. The resolve
event and its aliases, the vat's far listeners and vows, the Host's vow
rows, the node's redeem destinations and pending withdrawals, pending
answer releases, enliven groups, and the in-flight sturdyref fetch hold the
target. A stale target reads as absent: the vat refuses it with
`AlreadySettled`, the node does not claim it, and the stateless
`op:gc-answers` emit reports `GcUnderflow`. Under CapTP 1.0 a pending
outbound answer released before its resolve arrives is withheld, because
the partner's `op:resolve` names the position. The next profile resolves
through the resolver export, so the position frees at once.

**The answer row holds its resolver export.** `AnswerCell` holds
`resolver_export` under a presence flag. On an outbound row it is the
resolver the partner delivers to when it settles the answer, and on a local
promise's virtual inbound row it is the projection export that names it.
The release of an outbound answer takes the export from the row it is about
to drop and retires that export.

**The export row holds its purpose.** `ExportRow` holds its wire-delta
count, the binding of its CapTP cell (`slot.Binding`, with the cell rebuilt
from the binding and the index, because the index is the position and the
mint is local), and a `ResolverPurpose`, `.none` for an ordinary export.
`ExportTable.purpose` reads it as an optional, `setPurpose` writes it on a
bare live row, `replacePurpose` moves it in place, and `clearPurpose` takes
it off. The row's removal at count zero drops the purpose with it, so a
retired resolver's tombstone lasts exactly as long as the partner's mention
keeps the row. `Session.resolverPurpose` is the one read the inbound deliver
route makes (`engine.inbound.deliver_route.classify`): a switch over the
purpose routes a forwarding, shortening, node-settling, retired, or answer
callback, and an ordinary export or a local promise's projection falls
through to ordinary delivery.

**One owner per transition.** `resolver_export.zig` owns every write to the
pairing and keeps both rows in step. `mintMentionedResolverExport` runs when
an admitted deliver is encoded, before the send's apply installs the answer
row, and `applyValidatedSend` carries the export into the row it installs.
`bindFreshResolverExport` binds an installed answer. A prepared fetch has
one fallible step, the send, and installs its pairing after.
`replaceResolverPurpose` moves a listener's purpose between answers and the
Node consumer during settling convergence, and `removeOutboundResolver`
clears the row it unbinds. A mint whose mention rides outside `recordSend`
takes the mention's retain in the export's one row install
(`Session.allocateExportMentioned`).

**No reverse rows for the shortening purposes.** The question they answered,
whether a promise incarnation already has its one subscription, is a fact
about the promise, and `ImportedPromise.shortening_subscribed` holds it.
`shortening.nominate` sets it and refuses a second listener, `abandon`
clears it on a rollback that keeps the entry, and the entry's removal clears
it with the rest. `BiMap` indexes every value again. The V1.0 inbound
resolver link is its one user, installed before the answer row it would
name, and both of its sides take a row.

**Rows are sized on purpose.** The export row is the cost every warmed
session pays per export slot: `export_table.zig` pins it at 48 bytes and
`promises/types.zig` pins the purpose at 32. A settling source that may be
absent is `PromiseIncarnation.none` (stamp zero, which `nextStoreStamp` never
issues) rather than an optional, and a local promise's trace scratch keeps
the virtual answer's position and rebuilds its name.

## Scope (what this does not decide)

Import and inbound answer positions stay hashed under the secret multiplier,
because the partner chooses them. Local virtual answers and node route ids
keep their monotonic counters (ADR-0091). The vat's broken-far watermark is
a stamp (`Port.far_broken_stamp`), not a position. The inbound resolver
link stays a table. Which exports are resolvers, and what each purpose
means for the deliver that reaches it, is unchanged from ADR-0010, ADR-0095,
and ADR-0224.

## Alternatives Considered

- **Keep the hashed tables for own-side positions**: rejected because a
  secret-keyed hash defends against a chooser the session does not face,
  and a probe per table per question is the structure's cost.
- **A monotonic slab with no free list**: rejected because a long session
  would grow the vector without bound while the protocol lets the position
  return.
- **Withhold every freed answer until its notification is consumed, so bare
  positions stay unique**: rejected because a listener fire can mint a send
  that takes the freed slot before the stateless release emit runs, so the
  position alone cannot name the question across that turn.
- **Hold the stamp in the slot and keep bare positions in readers**: rejected
  because a reader with the position alone cannot tell its row from the next.
- **A purpose slab beside the export slab**: rejected because it is the same
  row in two places, and every transition must keep the two in step.
- **An optional purpose on the row**: rejected because the optional's flag
  costs a word beside a union that already has a tag, and the `.none` arm
  is never seen past `ExportTable.purpose`.
- **Keep the reverse rows for the shortening purposes**: rejected because
  the question they answer is about the promise, and the promise's entry
  already holds the incarnation.
- **Let the mint find the answer row in either order**: rejected because two
  orders for one pairing would be two ways to do one job. Each mint names
  its order.

## Consequences

ADR-0224's reasoning stands for the inbound link, and its rejected
alternative "a field on the answer cell for its resolver export" is
reversed: the reverse row was the second home, and it is gone. ADR-0223's
words now key the inbound link alone. An answered send writes its facts
into the rows its mints install and inserts into no table, and an inbound
deliver classifies its target by one row read.

The footprint moves from tables to rows. `AnswerCell` is 56 bytes with its
resolver export, `ExportRow` is 48 with its purpose and binding, and
`engine.Peer` holds a free-list head and a live count per slab where it
held hash-map headers and the resolver link's secret word
(`engine.peer_session_struct_budget_bytes`). `engine.events.Event` and the
Host's `VowRow` each carry the row stamp beside the position.
`OutboundAnswerSpaceExhausted` is gone: a slab index is 32 bits, and growth
past it fails as `OutOfMemory`. The sparse-position bench measures the
import table, the one a partner fills. `claimPromiseSettlingListener` and
`installNodeSettlingResolver` cannot fail.

`test/session/position_slab_test.zig` proves the slab's reuse order,
abandonment, withholding, and explicit growth. `test/session/answer_test.zig`
proves a settled position is asked again under a new identity and that
CapTP 1.0 withholds a pending one. `test/actors/vat/far_test.zig` proves a
stale far vow is refused while the position names a new question, and
`test/driver/gc_stateless_test.zig` proves a stale resolve cannot release
it. `test/session/resolver_test.zig` proves a purpose leaves with its row
and moves in place, `test/engine/peer/settling_test.zig` proves a released
shortening resolver stays deduplicated through the promise entry until the
source is released, and the settling convergence tests prove the in-place
transitions keep the answer rows in step. `test/session/bimap_test.zig`
proves the inbound link's pairs appear and leave together.
`test/engine/footprint_budget_test.zig` holds the warmed session's budget.

## Notes

ADR-0223 keeps the hash for partner-chosen positions. ADR-0225 gives a
process-minted handle the same index-plus-generation shape. ADR-0132's
facet budget keeps its per-session count, which actor churn spends whether
or not the export position comes back.
