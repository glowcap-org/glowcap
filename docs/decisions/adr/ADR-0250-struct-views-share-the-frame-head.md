---
id: ADR-0250
status: accepted
date: 2026-10-15
tags: [codec, engine, memory, model, performance, resilience, syrup]
decision: "Inbound decoding validates under bounded traversal and stores argument views, struct entries, and integer words in one bounded frame-owned byte region, with validated wire-backed fallback when storage fills."
supersedes: [ADR-0231, ADR-0242, ADR-0248]
superseded_by: []
amends: [ADR-0222, ADR-0243]
amended_by: []
---

# ADR-0250 Frame-backed inbound decoding

## Context

Validation, capability lifting, and handlers may each visit an argument tree.
Keeping every collection wire-backed repeats parsing and projection on each
visit. Caching only the top-level arguments leaves nested lists and structs
paying that cost. Unbounded caching would let a compact hostile message
amplify resident memory.

Syrup learns collection lengths at closing delimiters. Cap'n Proto supplies
lengths before its elements, but pointers may alias and amplify traversal.
The shared representation must respect both formats and the frame's lifetime.

## Decision

An owned inbound frame lends one bounded byte region in its head for
argument views, struct entries, and integer words. `model.view.ValueSlab`
accounts for aligned bytes and exposes typed claims for views and entries.
The region lives and retires with the frame, with no separate allocation.

`headViewsFor` in `src/ocapn/engine/events.zig` sizes the region from the
wire length under a cap. Small frames retain a floor that fits their
allocator class. Larger frames earn more room. A collection that cannot fit
stays wire-backed, so storage availability changes cost rather than which
messages are accepted.

Cap'n Proto claims known-length collections directly. Syrup reserves a
parent slot before reading its children, then settles the closed collection
into contiguous storage. Parent and child claims cannot overwrite each
other. Settlement handles overlap in whole values rather than swapping each
byte separately.

When a Syrup collection overflows, it restores the settled byte count from
before that collection and drops its open stack. Earlier siblings remain
live, and later siblings can reuse abandoned storage. Children of a
wire-backed parent cannot expose the discarded cached views. Validation
continues with the same size, depth, ordering, and capability checks.

The Cap'n Proto decoder fills cached views during its metered traversal.
A subtree left wire-backed is descended under that same traversal budget
before its backing escapes. This includes overflowed lists, struct values,
and locator hints. The budget belongs to the initial walk and never escapes
through a view. Later projections do not perform a second eager charge pass.

A nested Syrup list attempts an integer run in unused head storage. It
commits little-endian words only when every element fits `i64` and the
complete nonempty list fits the room and collection bound. A failed attempt
leaves cursor and storage unchanged for the general reader. Its speculative
prefix is bounded by the available room and one failed element.

The deliver's outer argument list, sets, and tagged values use general
views. Integer runs share the backing defined by ADR-0243. Typed accessors
can borrow compatible words directly, while unsupported host layouts or
general value backings require a copy.

Struct keys are validated during the initial walk, including singleton
keys. Cap'n Proto orders raw key bytes, and Syrup orders encoded String
keys. Both reject malformed UTF-8 before a view escapes.

## Alternatives Considered

- **Count the whole tree before filling storage.** This pays another scan
  even when the bounded region already suffices.
- **Allocate storage without a cap or in a separate per-frame buffer.**
  The first permits memory amplification, and the second adds an allocation.
- **Cache only argument slots and leave struct entries on the wire.**
  This preserves repeated key parsing and value projection.
- **Charge traversal separately or trust every list to fit.** Separate
  charging repeats projection, while trusting the cache leaves overflowed
  subtrees outside the amplification bound.
- **Build integer views before compacting them.** This pays the per-element
  representation and storage cost that a word run avoids.

## Consequences and evidence

Consumers read cached collections without reparsing wire bytes. Overflow
trades repeated projection for bounded memory and preserves the validated
frame as the backing owner. Caller-provided frame storage and the traversal
budget remain independent limits.

`test/codec/struct_slab_test.zig` compares both codecs and profiles at every
byte capacity and checks malformed singleton keys. Syrup slab tests in
`test/codec/syrup/decode_slab_test.zig` cover nested fallback, settlement,
integer runs, and siblings around abandoned collections.
`test/codec/capnp_malformed_test.zig` covers aliasing and nesting refusals.
`test/engine/parse_once_test.zig` and `test/foundation/frame_test.zig`
cover frame-head ownership and bounded fallback.

## Related decisions

ADR-0222 establishes argument storage in the frame head. ADR-0229 owns frame
admission. ADR-0243 owns integer-run wire representation. ADR-0241 owns
handler access, and ADR-0245 owns encoding borrowed views.
