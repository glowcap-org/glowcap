---
id: ADR-0253
status: accepted
date: 2026-10-17
tags: [session, codec, engine, performance]
decision: "The session's one admission walk takes the codec's meter and carries what the tree's values encode to, so a Syrup encode reads the tree once: the count pass walks the envelope alone and the fill pass holds the measure."
supersedes: []
superseded_by: []
amends: [ADR-0234, ADR-0246]
amended_by: []
---

# ADR-0253 One pass encodes an admitted tree

## Context

A Syrup encode renders a record in two passes over one generic writer
(`src/ocapn/codec/syrup/render.zig`): a count pass measures the record so
the frame is one exact allocation, and a fill pass writes it. On the
outbound path the count pass was a third walk over an admitted tree: the
session's inventory walk had visited every value at admission (ADR-0234),
and the fill followed the count, validating every text a second time. Cap'n
Proto builds its segments as it goes and has no count pass.

## Decision

- **The inventory walk meters.** `inventory.ofArguments`, `ofResolution`,
  and `ofMessage` take a comptime `Meter`, a type with `shallow(argument)`
  and `key(text)`, and `Inventory.wire_bytes` carries the sum: what the
  tree's values encode to outside the references and handoffs lowering
  rewrites, and outside the list a deliver's arguments ride in. Freight
  certification (ADR-0246) takes the same meter and returns
  `session.Freight` with both measures. `inventory.NoMeter` sizes nothing,
  for the session's own prepared sends and for a codec without a meter.
- **The codec owns its meter.** `codec.syrup.meter` sizes each value with
  the writer that fills it (`scalar.writeText`, `scalar.writeDigits`, and
  the record openers) and checks nothing, because the fill refuses an
  invalid text before any byte is published. `meter.mention` sizes a listed
  reference or handoff at encode, after lowering fixed the positions whose
  decimal widths the walk could not know. Every registered codec declares
  `meter` as an optional type, and Cap'n Proto declares null.
- **The engine composes the two.** `Peer.inventoryMessage`,
  `Peer.inventoryResolution`, and `Peer.certifyFreight` pick the meter by
  the session's codec, and `admit` (`src/ocapn/engine/outbound/encoded.zig`)
  sums the inventory's measure, each slot's mention, and the freight into
  the `values` that `codec.dispatch.encodeBodyForProfile` takes.
- **The sized encode holds the measure.** `render.renderRecordExactSized`
  runs the count pass with the values known: `encode.writeDeliverArguments`
  and `encode.writeFulfillment` take them in place of the tree, so the count
  pass walks the envelope alone. A measure that disagrees with the writer,
  or a non-zero measure for a message with no tree, is a returned
  `EncoderInvariantViolation`, and no frame exists.
- **Overflow is refused once.** The owned measure, the inventory walk, and
  the freight walk add with saturating arithmetic and refuse a saturated
  total as `MalformedView` at the end, in place of a checked addition per
  value. A synthetic run whose charge saturates is refused before a word is
  read.

## Scope (what this does not decide)

A message the engine prepares itself (`encodeMessageForProfile`) and a
queued resolution carrier still encode in two passes, because their
inventory is released at admission. The session-table cost of a send, one
insert per table per open answer, is untouched.

## Alternatives Considered

- **Encoding into a growable buffer.** Rejected: the frame would be one
  allocation plus a copy or a shrink, where the exact allocation is the one
  named cost.
- **A meter in the session or model layer.** Rejected: the session does not
  import a codec, and a byte count per arm beside the writer would drift.
  The meter lives with the writer, and the walk takes it as a type.
- **A fallible meter that validates text.** Rejected: it would add the
  codec's errors to the walk, and the fill validates once in any case.

## Consequences

- An admitted tree is read once at admission and once at fill. The count
  pass over the arguments and its second UTF-8 validation of every text are
  gone, and the decimal width of every length and position is computed once,
  in the meter.
- Evidence: `test/codec/syrup/meter_test.zig` holds a sized encode of every
  argument arm, a resolution, a break, borrowed freight, and a word run to
  the measured encode's bytes, and refuses a measure one byte off in either
  direction. `test/session/inventory_test.zig` and
  `test/session/freight_test.zig` run under `NoMeter`.

## Notes

ADR-0234 settled the one walk, which now meters. ADR-0246 settled freight
certification, which now meters too.
