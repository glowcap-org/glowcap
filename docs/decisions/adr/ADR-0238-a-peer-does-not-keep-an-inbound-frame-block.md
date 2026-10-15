---
id: ADR-0238
status: accepted
date: 2026-10-14
tags: [engine, inbound, memory, performance]
decision: "A peer does not keep an inbound frame block between frames. A kept block past the C allocator's small class measured no drop in instructions per round trip on the `report` rows, because the allocator hands a block freed at the same size straight back, and the pool itself cost about seventy instructions a turn and forty bytes a session."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0238 A peer does not keep an inbound frame block

## Context

An owned inbound frame is one block that carries the parse and the argument
views in front of the wire bytes (ADR-0231), and the views grow with the
frame up to a cap. The C allocator serves a block up to its small class from
a per-thread cache, and a larger one through its bins. The `greet` row's
count rose by about a thousand instructions when its block first crossed the
class, which suggested that every frame past the class, such as the `report`
row's, paid that walk twice per round trip.

The candidate was an allocator over the peer's own, owned by the peer, that
kept the last block past the small class up to 16 KiB and handed it to the
next frame of the same size class. It was built, its allocation and
footprint budgets held, and it was measured with the callgrind recipe in
`bench/README.md`.

## Decision

The peer keeps nothing. Instructions per round trip on the `report` rows,
caller and server, did not move outside the recipe's floor, and the
per-function diff showed why. The allocator's own cost for the frame's block
was already small: a block freed and taken again at the same size comes
straight back from the allocator's unsorted bin or top chunk. The kept block
added its own bookkeeping, about seventy instructions a turn, and made the
allocator consolidate the neighbouring frees it had merged before, which
cost about as much again. The greet row's thousand was the cost of crossing
the class once in a different heap layout, not a per-frame charge.

| Row, server | Allocator on every frame | One kept block |
| --- | --- | --- |
| Syrup `report` | 52,097 | 52,271 |
| capnp `report` | 49,760 | 49,855 |

The engine's `small_block_bytes` keeps its meaning as the line the smallest
calls stay under. A pool past it needs a measurement that shows the
allocator losing, on the allocator the build ships against.

## Scope (what this does not decide)

A different allocator, or a frame cap that puts most blocks far above the
class, could change the measurement. The recipe is in `bench/README.md`.

## Alternatives Considered

- **A size-classed cache in front of every peer allocation.** Rejected
  without building: it reimplements the allocator for every table and queue.
- **A pool shared by every session of a host.** Rejected without building:
  the engine has no shared owner, and the per-peer slot already showed the
  allocator was not the cost.

## Consequences

- The allocation budget keeps the owned frame as the one allocation a
  steady-state deliver costs, at any frame size.
- The plan that proposed the pool closes without it.
