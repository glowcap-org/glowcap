# Test data

Saved ocapnviz documents kept for testing rather than for teaching. The
scenarios the app ships in its picker live in
[`../src/fixtures/`](../src/fixtures/) and are TypeScript modules. These are
plain saved documents, the same JSON the Build mode writes, and the app opens
them through its ordinary load path.

## `the-kids-masterpiece.json`

Two kids were let loose in Build mode and made this. It is kept because it is a
real document that nobody designed to be reasonable, which is a thing the
authored scenarios cannot be.

It carries more sessions than any shipped scenario reaches, hand-placed across a
much wider stage than an authored layout uses, with entities whose durations are
implicit rather than stated. Those are the properties worth having: it is
playback and rendering work at a shape no fixture in `../src/fixtures/`
produces.

It earns a second place as a parser fixture. A schema or loader change that
breaks real saved documents breaks this one first, because it was written by the
Build mode rather than by hand to match the schema.

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
byte, so the generator is worth keeping while eight megabytes of
derived JSON are not. Each one says in its own About what it is and carries
PROV-O provenance back to the document it grew from.

The factor multiplies peers, sessions and messages, keeps every profile, codec
and CapTP version the source used, and holds the stage area fixed, so density
rises with the count. Density is the point because nearby entities create the
cost: labels dodge, edge chips walk their corridors, and curves bundle between
pairs of peers. Spreading the copies
over a proportionally larger stage would leave every neighbourhood looking as it
did.

Two things to hold when reading a number off one of these. Fit the stage first,
because off-screen entities are culled and an unfitted reading is of whatever
was in view. And take it in a real browser: headless Chromium rasterizes through
SwiftShader on the CPU, which costs about twelve times what a GPU does on the
same document, so a headless timing measures software rendering rather than the
app.

What they have measured so far is under the performance item in
[`ocapnviz-backlog.md`](../../../docs/planning/ocapnviz-backlog.md), which is
where a claim about the app's speed belongs.
