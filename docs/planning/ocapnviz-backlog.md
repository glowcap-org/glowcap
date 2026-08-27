# ocapnviz backlog

Status: active plan. Edge upload batch has landed; the open remainder is a
real-GPU re-measure and a frame-budget ratchet. Timeline click-below-fold and
fit half-row defects from the earlier list are done; other landed work lives
in git history.

## Performance: playback and editing cost too much

The visualizer should carry ordinary documents without the user waiting on the
tool. It does not yet. Cost shows up in two places that share the same budget.

**Editing.** On
`apps/ocapnviz/test-data/the-kids-masterpiece.json` (31 peers, 90 sessions, 52
messages; see
[`apps/ocapnviz/test-data/README.md`](../../apps/ocapnviz/test-data/README.md)),
these cheap wins have landed:

- Multi-select drag: one `repositionNodes` / placement pass
- All-pinned topologies skip the force anneal; placement checks equilibrium
  before `runForce`
- Mid-drag stays quiet on `docVersion`; timeline uses `useDocVersion`
- **Transactions coalesce stage work:** Unpin all and multi-delete used to pay
  one cold `recompute` or one world rematerialize *per member*. Inside a
  transaction, layout/seek defer to `endTransaction` (one anneal, one seek).
  Deletes also refresh keyframes so removed peers do not linger in the solver.
- **Session wires share one stroke batch** (same path playback uses below).

**Playback.** On some machines the same corpus drops frames; when a group of
sessions appears, the playhead jumps instead of advancing smoothly. A PixiJS
ECS renderer should carry ~173 entities over ~1.4s without noticing, so the
cost is how the work is organised.

**Evidence on a real GPU (playback).** On an M3 Max browser, this document holds
8.3ms a frame idle of long tasks. `deno task stress-tests` writes larger copies.
With the stage fitted so nothing is culled:

| entities | frame p50 | frames over 33ms |
| --- | --- | --- |
| 173 (kids masterpiece) | 8.3ms | none |
| 692 | 9.9ms | none |
| 1,384 | 19.0ms | 4 of 73 |
| 2,768 | 34.5ms | 21 of 42 |

One fix already landed: `materializeWorldAt` used to scan the document per
entity (quadratic). Indexing that cut the 2,768-entity case from 51ms to 29ms.

Headless Chromium readings are not usable as absolute frame rates: SwiftShader
rasterizes on the CPU and makes every frame look like the app's fault. A
same-host before/after or scene-isolation pass can still locate work.

**Static Timeline cache (landed; real-GPU re-measure pending).** The Scrubber
used to clear, rebuild, and rasterize every lane mark when only the playhead
moved. Its viewport-sized static scene is now a retained Pixi texture; the
playhead, hover ghost, marquee, and snap line paint in a live layer above it.
Every lane/view/selection input still invalidates the texture. On the same
production build and SwiftShader host, the 1,384-entity stress document moved
from 984ms to 121ms frame p50; with Stage bodies hidden, which isolates the
Timeline more sharply, it moved from 910ms to 34ms. Those are relative
diagnostics, not GPU claims. Cached and uncached device-scale-2 screenshots
were pixel-identical across 6.4 million pixels, and the texture's memory is
bounded by the visible Scrubber viewport rather than document size.

**Edge upload batch (landed; re-measure pending).** At 2,768 entities, about
42% of playback time was in `bufferSubData` under Pixi's `updateBuffer`: a
moving peer re-tessellated and re-uploaded each of its wires. Session wires
now share one `EdgeStrokeBatch` Graphics
(`apps/ocapnviz/src/render/edge-stroke-batch.ts`): any dirty wire marks the
batch, and one clear+restroke uploads once. Per-edge hit proxies and chips
stay as they were; selection/hover halos paint above the shared wire layer
so a mark stays visible at crossings. Shader-carried curves remain an option
if a real-GPU pass still shows the tessellation itself as the cliff.

Smaller leftovers that have landed: the engine builds one `frameGeometry`
(claims + session bundles + time bundles + per-session curves) per stage
pass for flight and the Stage to share; claim/bundle tables stay memoized
while the standing set is stable; time bundles stay memoized across playback
ticks and mid-drag; settled layout eras skip per-node writes; hidden-body
session wires skip Bezier stroke/upload; Inspector shells subscribe to
`docVersion` + clock so mid-drag no longer re-reconciles Connections and the
Details chrome (field panels that track live pins still follow `version`).

**Done when** kids masterpiece (and smaller compositions) can be edited with
multi-node moves and Unpin all without the tool fighting the user, playback on
the reporting machine has no visible playhead jump, and a test holds the frame
budget so the gain cannot quietly rot.
