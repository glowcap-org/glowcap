---
id: ADR-0234
status: accepted
date: 2026-10-14
tags: [session, engine, performance]
decision: "A session walks an outbound argument tree once at admission, certifying what no later pass changes and listing the slots the later passes return to, and lowering, shortening, projection, reference certification, and export recording loop over that list."
supersedes: []
superseded_by: []
amends: [ADR-0069]
amended_by: [ADR-0246]
---

# ADR-0234 One walk inventories an outbound tree

## Context

A deliver that left through `Peer.send` walked its argument tree six times
before it was encoded: the Node counted the foreign routes it would project,
lowering rewrote node-local tokens to wire references (ADR-0069), shortening
rewrote far promises to their targets, admission measured the bytes the queue
would retain, validation certified nesting, struct keys, set uniqueness, and
every reference, and apply retained the exports the tree mentions. An answer
settlement walked its resolution as many times, and measured it twice. Each
walk was a recursive switch over every model arm, and callgrind on the
`report` row of `bench/iroh_bench.zig` put the six at about a tenth of the
caller's instructions per round trip. The walks also had to agree on the
nesting bound, the by-value root of a resolution, and which arms hold a
reference, with nothing but review holding them together.

## Decision

`src/ocapn/session/inventory.zig` owns the one walk. `ofArguments`,
`ofResolution`, and `ofMessage` certify the facts no later pass changes, the
nesting depth, struct key uniqueness, and the retained bytes, and return an
`Inventory`: the bytes, and the slots that hold a reference, a handoff, or a
set, in tree order. A slot is a pointer into the tree's heap, or `root` for a
resolution's by-value fulfillment, which its owner resolves. The engine takes
the inventory once at `enqueueRecorded` (and once per answer settlement,
relayed resolution, or listener drain) and hands it to every pass: `lower`
and `shortening` rewrite the listed references, the Node's `walk` counts,
collects, replaces, and restores projections at the listed slots,
`certifySent` certifies each reference, handoff, and set after the rewrites,
and `recordMentions` retains the exports. Admission charges the queue row the
message's envelope plus the inventory's bytes, so no pass measures again.

Sets are listed after their items and certified after shortening, because
shortening can fold two distinct promises onto one target. A set that becomes
duplicate that way is refused before any export is retained, as it was when
validation ran last. The list is one allocation per inventoried tree that has
a slot to list, and a tree with none allocates nothing, which is the shape of
an ordinary application message.

## Scope (what this does not decide)

The inventory lives for admission and is freed when the message is queued.
The queued row still carries the owned message, and retraction (ADR-0194)
still walks it. A later step keeps the frame and the list in the row. The
host's own lowering walk above the engine is unchanged.

## Alternatives Considered

- **Keep the walks and share their switch**: one generic visitor with six
  callbacks. Rejected because each walk still visits every arm of every
  argument, and the cost is the visits, not the code.
- **Build the list where the tree is built**: the Vat or a binding hands the
  session the references it used. Rejected because the session owns
  validation and cannot trust a caller's list, and bindings build trees too.
- **Certify sets before shortening**: list sets with references and fold
  them in the one walk. Rejected because a set whose promises shorten onto
  one target would reach the wire with a duplicate the encoder then refuses
  after exports were retained.

## Consequences

- Every outbound pass is a loop over the slots, so a tree's cost after the
  walk is proportional to its mentions, not its size.
- The nesting bound, the by-value root, and the set of reference-bearing
  arms have one owner. A new model arm that carries a reference extends the
  inventory walk, and the certify and record passes refuse an unlisted arm.
- Measured with callgrind on the `tcp` loopback bench, instructions per
  round trip, within the recipe's floor: the Syrup `report` caller fell
  from about 82,900 to 69,000 and the Cap'n Proto one from about 82,300 to
  68,300, and the `greet` caller from about 25,500 to 24,900. The `report`
  servers fell by about 300 each. The `greet` server rose by about 60,
  because its reply is one string, and one walk with a list to keep costs
  about what the five short walks it replaced cost on a single node.
- Evidence: `test/session/inventory_test.zig` pins the measure, the slot
  order, the nesting bound with an empty container, the duplicate key, the
  allocation shape, and the set that becomes duplicate after shortening.
  Every engine and session test passes unchanged.

## Notes

ADR-0069 settled lowering at the one chokepoint, which the inventory now
feeds. ADR-0222 and ADR-0231 settled the inbound side's parse-once head.
