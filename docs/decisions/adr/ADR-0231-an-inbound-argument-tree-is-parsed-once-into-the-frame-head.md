---
id: ADR-0231
status: superseded
date: 2026-10-14
tags: [model, codec, engine, performance]
decision: "An owned inbound frame's head lends room sized by the frame for the views of the whole argument tree, both codecs fill it in one pass, and a sequence the room cannot hold stays wire-backed."
supersedes: []
superseded_by: [ADR-0250]
amends: []
amended_by: []
---

# ADR-0231 An inbound argument tree is parsed once, into the frame head

[ADR-0250](ADR-0250-struct-views-share-the-frame-head.md) consolidates this decision. It retains bounded frame-owned caching and fallback, and replaces fixed view slots with typed byte storage for entries and integer runs.

## Context

ADR-0222 lent the Syrup decoder room in the frame head for four views and
filled it with the top-level argument list only, so a nested list stayed
wire-backed and every consumer that walked it parsed its bytes again. The
Cap'n Proto decoder ignored the room: every list was backed by the segment,
and each element read derived a segment reader and projected the element
afresh. Profiling the `report` call of `bench/iroh_bench.zig` with callgrind
(a symbol, a string, eight strings, sixty-four integers, one integer) showed
the cost. On the Syrup server more than half the instructions re-read list
elements across the validation, materialization, and lift walks. On the
Cap'n Proto server the same walks spent most of their time rebuilding
readers and views. The room was also too small for the call's five
top-level arguments, so even that list was backed.

The room could not simply grow and recurse. A Syrup list learns its length
at its closing delimiter, and a nested list that claims room while its
parent is still open would land in the slots the parent writes next.

## Decision

`model.view.ValueSlab` has two ends. A codec that knows a sequence's
length before reading its elements claims contiguous room from the bottom.
A codec that learns the length at the closing delimiter pushes each element
onto a stack at the top and, when the sequence closes, settles them into a
contiguous claim at the bottom. An open sequence and the sequences nested
in it never collide, and a sequence the room cannot hold drops what it
pushed and comes back wire-backed, after which the sequences nested in it
are read extent-only, because a backed reader parses them afresh.

The Syrup decoder (`readElements` in `codec/syrup/decode/values.zig`) pushes
and settles every list, set, and tagged value it meets, keeping the set
order check. The Cap'n Proto decoder (`neutralArgs` in
`codec/capnp/decode/values.zig`) claims each composite list's element count
and fills it. A struct's entries stay wire-backed on both codecs, since an
entry carries a key beside its value and does not fit the slab's element.
ADR-0250 replaces those fixed slots with typed byte claims and caches struct
entries too. It also reclaims children of an overflowing Syrup collection.

The engine's owned inbound frame lends the room from its head, behind the
parse slot (`Frame.initHeaded` with a tail of views, `Head.slabOf`). A frame
short enough that its whole block fits the C allocator's small class with
the floor of `head_argument_views` keeps the floor, so the smallest calls
pay the same as before. A longer frame earns one view per `head_view_bytes`
of wire up to `head_views_cap` (`headViewsFor`), so its head grows with the
message it carries and never past the cap. The views are transient, freed
with the frame.

## Scope (what this does not decide)

The host still materializes a delivered message's views into owned values
and lifts them before a handler runs, so the application reads a copy. A
handler that reads the views directly is the next seam on the inbound path.
The outbound path's walks over a message are the next seam on that side.
ADR-0250 extends the head to struct entries.

## Alternatives Considered

- **Parse nested lists in a second pass once the parent has settled**: one
  more tokenization of every nested byte, where the stack costs one 80-byte
  copy per view. The copy is cheaper and the story is one pass.
- **Count the tree first and allocate the head exactly**: a full scan of the
  bytes before the parse, paid on every frame to save unused room that costs
  nothing, since the views are never zeroed.
- **Size the head by the frame's bytes alone, with no cap**: a frame of
  one-byte booleans would earn eighty bytes of room per wire byte. The cap
  bounds the head paid per in-flight frame at ten kilobytes, and a denser
  list falls back to the bytes, which costs time and never memory.
- **Size every frame proportionally, with no small-frame floor**: measured,
  and the `greet` row's forty-five byte frame earned eleven views, which
  pushed its block past the C allocator's per-thread cache and cost each
  side several hundred instructions in the allocator for views it never
  used. A frame that fits the small class keeps the floor.
- **Settle a Syrup sequence with the standard reverse and copy**: measured
  at fifteen thousand instructions on the `report` row, because the
  standard reverse swaps a view byte by byte. The settle copies the disjoint
  part down in whole views and reverses only the overlapping slots.
- **Parse into the session's receive arena instead of the head**: the views
  must live as long as the frame they borrow, and the frame's own block is
  the owner with that lifetime.

## Consequences

- A view-backed sequence answers `at` and `next` from the views, so every
  walk after the parse reads no wire bytes, on both codecs, at any depth the
  room covers.
- The owned inbound frame's block is larger past the small class: the fixed
  head plus up to the cap in views. The `greet` row's frames keep the floor,
  and the `report` row's deliver earns the cap.
- Measured with callgrind on the `tcp` loopback bench, instructions per
  round trip, three runs within the recipe's floor: the Syrup `report`
  server fell from about 111,800 to 59,100 and the Cap'n Proto one from
  about 68,000 to 56,700, with both callers and both `greet` threads
  unchanged within the floor except the Cap'n Proto `report` caller, up
  about 1,100 because its reply frame is just past the small class. A
  retained per-session pool for inbound frame blocks would remove that
  cost for every frame, and is the plan's to take.
- ADR-0250 reclaims cached children when their parent overflows the room,
  so later siblings can reuse that storage.
- Evidence: `test/codec/syrup/decode_slab_test.zig` pins settling order,
  the exact-fit overlap, the nested fallback, and the set order check.
  `test/codec/capnp_test.zig` pins the claimed tree and the backed fallback.
  `test/engine/parse_once_test.zig` pins the head's room, a list that fits
  it, and a dense list that falls back and reads the same.
  `test/foundation/frame_test.zig` pins the headed frame.

## Notes

ADR-0222 settled the slab and the head. ADR-0229 settled the one admission
door that lends it.
