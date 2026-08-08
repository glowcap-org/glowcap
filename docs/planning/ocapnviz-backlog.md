# ocapnviz backlog

Status: active plan. One open item. Timeline click-below-fold and fit half-row
defects from the earlier list are done; other landed work lives in git history.

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

What remains when many wires move at once is the edge path below.

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

Headless Chromium readings are not usable: SwiftShader rasterizes on the CPU
and makes every frame look like the app's fault.

**What is left.** At 2,768 entities, about 42% of playback time is in
`bufferSubData` under Pixi's `updateBuffer`: a moving peer re-tessellates and
re-uploads its wires. Editing pays that same path when many nodes move at once.
Cutting it means batching edges into one geometry, or carrying the curve in a
shader. Neither is a small change. Smaller leftovers: Sidebar still wakes on
`useEngineVersion` mid-drag; claims/bundles are built twice per playing frame.

**Done when** kids masterpiece (and smaller compositions) can be edited with
multi-node moves and Unpin all without the tool fighting the user, playback on
the reporting machine has no visible playhead jump, and a test holds the frame
budget so the gain cannot quietly rot.
