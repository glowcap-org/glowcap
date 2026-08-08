# ocapnviz — OCapN network topology visualizer

A real-time visualizer for OCapN networks. Peers and sessions animate as a
deterministic entity world advanced by a playback clock and drawn with PixiJS.
Each peer carries an implementation profile (`goblins`, `pancake`, and so on),
and each session carries its codec, CapTP version, and lifecycle state.

ocapnviz is the protocol-timeline plane of pancake's observability surface, and
[`docs/roadmap.md`](../../docs/roadmap.md) records what that surface ships and
what it does not. It replays
timelines that `pancake griddle run` produces, converted by
`scripts/griddle-import.ts`, and it reads the same schema live from a running
pancake host. It runs on its own Deno toolchain under `apps/ocapnviz/`.

## Quick start

```bash
cd apps/ocapnviz
bash dev.sh          # vite dev server (Ctrl-C-friendly)
deno task test       # unit tests
deno task typecheck  # deno check src/main.tsx
```

From the repository root, `zig build ocapnviz-test` runs the suite and is part
of `zig build check`, skipping itself on a machine without deno. The step
`zig build ocapnviz-check` adds the type-check, the formatter, and the linter,
and needs deno outright. None of them reach `scripts/`, so the Playwright probes
there are proved only by being run.

The dev server defaults to <http://127.0.0.1:5173>. Hit **Play** and watch Alice
introduce Bob to Carol. The new Bob-to-Carol session lands on `syrup/v1_0`
because Bob is Goblins-flavored, so codec and CapTP version negotiate per
session.

`dev.sh` supervises vite so that Ctrl-C and closing the terminal stop the dev
server. A bare `deno run -A npm:vite` can outlive its terminal through deno's
npm-compat layer and keep holding the port. A vite process showing `PPID 1` in
`ps` is one of those orphans; kill it and start fresh.

## Live mode

Switch the top-bar mode to **Live** and point the left pane's URL field at any
websocket streaming the timeline schema. The rooms server is one: start it with
`ROOMS_VIZ_PORT=9300` and use the printed `ROOMS-VIZ-LISTENING` address (see
[rooms developing](../rooms/developing.md)). Other peers publish their own
traces to the same endpoint, so sessions that server never carries still appear.

Live connects as soon as you enter it, and the dot under the URL turns green
when a feed is there. Being connected is not recording. Press **Record** to
start a capture, and from that moment every session and message the room carries
draws as it happens. The feed replays the sessions already open, so the picture
is complete rather than filling in as traffic happens to mention each one.
**Stop** hands the capture to Play, where it replays like any other recording.

Each `op:start-session` animates from its observed depart timestamp to its
observed arrival. The layout system reads a `<region>-` prefix on peer ids and
pulls each peer toward its region centroid. The recognized prefixes are `us` or
`na`, `eu`, `af`, `ap` or `as`, `sa`, and `oc`. Peer ids without one, such as
`alice` or `dialer-3`, fall back to the concentric layout.

## Architecture

```text
TimelineDocument                ← events at simulated-clock timestamps
            ↓ Engine ingests
Clock                           ← simulated time, play/pause/speed
            ↓ tick(wallDt) → simDt
World (miniplex ECS)            ← entities + components
            ↓ Systems (fixed order each tick)
   TimelineSystem               (events → world mutations)
   KeyframeLayoutSystem         (lerp peer positions between keyframes)
   MessageFlightSystem          (eased interpolation along edges)
            ↓ RenderSystem
PixiJS scene graph              ← derived from world each frame
            ↓ WebGL
Canvas
```

Three properties hold by construction:

- **Events are the primitive.** Snapshots are derived by replay, and authoring
  is event-by-event in [`src/fixtures/`](src/fixtures/).
- **Position is a pure function of `t`.** Layout keyframes are computed up front
  and the runtime interpolates between them, so scrubbing forward and back
  visits identical numbers.
- **The renderer is a projection.** PixiJS sprites are rebuilt from the world
  each frame, and nothing else holds simulation state.

Everything draws into one full-viewport canvas that sits behind the React
panels. The Stage, the Scrubber, and the Overview share that scene graph and
that ticker. Each panel leaves an empty `[data-region]` marker div where its
scene should appear, and `src/render/RegionRegistry.ts` tracks where those
markers land so `src/render/UnifiedCanvas.tsx` can position each scene and set
its hit area.

The shared UI idioms, and the one authority for each, live in
[`docs/design-principles.md`](docs/design-principles.md). The gesture pipeline
has its own specification in
[`docs/interaction-model.md`](docs/interaction-model.md).

## Troubleshooting

If Vite errors with `ENOENT ... node_modules/.deno/<pkg>@<ver>/...` after a
dependency change, the pre-bundle cache is stale. Wipe it and reboot:

```bash
rm -rf .vite node_modules .deno && bash dev.sh
```

If editing `vite.config.ts` seems to have no effect, restart the dev server by
hand. The watcher ignores config files because Vite's auto-restart used to wedge
the wrapper chain; `vite.config.ts` carries the details.
