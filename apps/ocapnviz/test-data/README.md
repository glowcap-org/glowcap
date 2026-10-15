# Test data

Saved ocapnviz documents kept for testing. The scenarios in the app's picker are
TypeScript modules in [`../src/fixtures/`](../src/fixtures/). These are plain
saved documents, the same JSON Build mode writes, and the app opens them through
its ordinary load path.

## `the-kids-masterpiece.json`

Two kids were let loose in Build mode and made this. It is a real document that
nobody designed to be reasonable, which the authored scenarios cannot be.

It carries more sessions than any shipped scenario, hand-placed across a much
wider stage than an authored layout uses, with entities whose durations are
implicit rather than stated. That gives playback and rendering a shape no
fixture in `../src/fixtures/` produces.

It is also a parser fixture. Build mode wrote it, not a hand matching the
schema, so a schema or loader change that breaks real saved documents breaks
this one first.

It validates against `TimelineDocument` in
[`../src/engine/timeline.ts`](../src/engine/timeline.ts). Its `metadata` and
`provenance` blocks use the app's own Dublin Core and PROV-O vocabulary from
[`../src/schema/provenance.ts`](../src/schema/provenance.ts).

## `stress-*x.json`

Written by `deno task stress-tests`, which grows the kids' document by
whole-number factors so how the visualizer scales can be measured rather than
guessed. The standard set is 4x, 8x, 16x, 32x and 64x. Naming factors writes
only those.

They land beside this file so the app's Open dialog can reach them, and
`stress-*x.json` is gitignored. A fixed seed reproduces any factor byte for
byte, so the generator is kept and the derived JSON is not. Each file says in its
own About what it is and carries PROV-O provenance back to the document it grew
from.

The factor multiplies peers, sessions and messages, keeps every profile, codec
and CapTP version the source used, and holds the stage area fixed, so density
rises with the count. Density is the point because nearby entities create the
cost: labels dodge, edge chips walk their corridors, and curves bundle between
pairs of peers. Spreading the copies over a larger stage would leave every
neighbourhood looking as it did.

Two rules when reading a number off one of these:

- Fit the stage first. Off-screen entities are culled, so an unfitted reading
  is of whatever was in view.
- Use a real browser. Headless Chromium rasterizes through SwiftShader on the
  CPU, which costs about twelve times what a GPU does on the same document, so a
  headless timing measures software rendering.

This file is where a claim about the app's speed belongs. On an M3 Max browser,
`the-kids-masterpiece.json` holds 8.3ms a frame, idle of long tasks. With the
stage fitted so nothing is culled, `deno task stress-tests` copies give:

| entities | frame p50 | frames over 33ms |
| --- | --- | --- |
| 173 (kids masterpiece) | 8.3ms | none |
| 692 | 9.9ms | none |
| 1,384 | 19.0ms | 4 of 73 |
| 2,768 | 34.5ms | 21 of 42 |

Playback restrokes and bulk layout work have regression checks on this corpus.
The [roadmap](../../../docs/roadmap.md) tracks whether GPU tessellation needs
more work.
