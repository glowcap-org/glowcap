# ocapnviz: OCapN network topology visualizer

ocapnviz draws CapTP sessions and messages on a timeline so you can watch a
live Rooms server or replay a recorded run. Peers and sessions animate on a
playback clock and are drawn with PixiJS, so a timeline always plays the same
way. Each peer records which implementation it runs (`goblins`, `glowcap`, and so on),
and each session carries its codec, CapTP version, and lifecycle state.

ocapnviz replays timelines that `glowcap griddle run` produces, converted by
`scripts/griddle-import.ts`, and reads the same schema live from a running
glowcap host. It runs on its own Deno toolchain under `apps/ocapnviz/`. The
[roadmap](../../docs/roadmap.md) tracks remaining work, and measured performance
numbers are in [`test-data/README.md`](test-data/README.md).

## Quick start

From the repository root:

```bash
zig build ocapnviz-dev   # vite dev server; open the printed URL
```

Inside `apps/ocapnviz/`, the same server is `bash dev.sh`, and the suite and
type-check are `deno task test` and `deno task typecheck`.

Checks, from the repository root:

- `zig build ocapnviz-test` runs the suite and is part of
  `zig build runtime-check`. Deno is part of the declared toolchain, so a
  missing Deno is reported before any runtime checks start.
- `zig build ocapnviz-check` adds the type-check, formatter, linter, and
  production bundle, including the tools under `scripts/`. It confirms that each
  Playwright script can run. A claim about browser behavior counts only when
  its script has run against the app.

The dev server defaults to <http://127.0.0.1:5173> and answers only localhost
Host headers, so a laptop run is not a LAN service. The devcontainer binds
`0.0.0.0` inside the container and answers any Host header, so Compose's
host-loopback publish reaches Vite. Open that published port as localhost.

Hit **Play** and watch Alice introduce Bob to Carol. The new Bob-to-Carol
session lands on `syrup/v1_0` because Bob is Goblins-flavored, so codec and
CapTP version negotiate per session.

`dev.sh`, the body of `zig build ocapnviz-dev`, supervises vite so that Ctrl-C
and closing the terminal stop the dev server. A bare `deno run -A npm:vite` can
outlive its terminal through deno's npm-compat layer and keep holding the port.
A vite process showing `PPID 1` in `ps` is one of those orphans. Kill it and
start fresh.

## Live mode

Switch the top-bar mode to **Live** and give the left panel the trace sturdyref
printed as `ROOMS-TRACE-LISTENING`. The rooms server publishes one when started
with `--trace` (see
[rooms operating](../rooms/operating.md#watching-the-room-live)). ocapnviz loads
its WebAssembly Host on demand and connects to the trace. The endpoint accepts a
socket only from a viewer that presents the sturdyref's secret part (its
swissnum) on the socket itself, so the pasted announcement is the whole setup. Other peers publish their own traces
to the convergence endpoint with the same secret, so sessions the room
server never carries still appear.

Live connects as soon as you enter it. The badge under the sturdyref says
**connecting** while it dials, **waiting** until the first observation arrives,
and **connected** once the feed has spoken. Being connected is not recording.
Press **Record** to start a capture, and from then on every session and message
the room carries draws as it happens. **Stop** hands the capture to Play, where
it replays like any other recording.

The trace first replays the sessions already open, so the picture is complete
from the first frame. A viewer that disconnects or falls behind reconnects and
gets a fresh replay of the current state.

Each `op:start-session` animates from its observed depart timestamp to its
observed arrival. The layout system reads a `<region>-` prefix on peer ids and
pulls each peer toward its region centroid. The recognized prefixes are `us` or
`na`, `eu`, `af`, `ap` or `as`, `sa`, and `oc`. Peer ids without one, such as
`alice` or `dialer-3`, fall back to the concentric layout.

## Architecture

```text
TimelineDocument                ← entities, observations, authored events
            ↓ Engine (public door: tick, dispatch, seek)
Playback                        ← drain intents, advance Clock, seek
            ↓ materializeWorldAt(t)
World (miniplex ECS)            ← entities whose effective range contains t
            ↓ Systems (fixed order each tick)
   KeyframeLayoutSystem         (node positions as a function of t)
   MessageFlightSystem          (eased interpolation along session edges)
            ↓ Stage / render-frame
PixiJS scene graph              ← derived from world each frame
            ↓ WebGL
Canvas
```

Three properties hold:

- **Events are the source of truth.** Snapshots are derived by replay, and authoring
  is event-by-event in [`src/fixtures/`](src/fixtures/).
- **Position is a pure function of `t`.** Layout keyframes are computed up front
  and the runtime interpolates between them, so scrubbing forward and back
  visits identical numbers.
- **The renderer only draws.** PixiJS sprites are rebuilt from the world
  each frame, and nothing else holds simulation state.

Everything draws into one full-viewport canvas behind the React panels. The
Stage, the Scrubber, and the Overview share that scene graph and ticker. Each
panel leaves an empty `[data-region]` marker div where its scene should appear.
`src/render/RegionRegistry.ts` tracks where the markers land so
`src/render/UnifiedCanvas.tsx` can position each scene and set its hit area.

The shared UI patterns, and where each one is defined, are in
[`docs/design-principles.md`](docs/design-principles.md). The gesture pipeline
is described in
[`docs/interaction-model.md`](docs/interaction-model.md). The cursor rules are in
[`docs/cursor.md`](docs/cursor.md). The document itself is described in
[`docs/data-model.md`](docs/data-model.md) and
[`docs/temporal-model.md`](docs/temporal-model.md), the reasoning behind the
three top-level modes in [`docs/three-mode-design.md`](docs/three-mode-design.md),
and the timeline authoring verbs in
[`docs/timeline-design.md`](docs/timeline-design.md).

## Troubleshooting

If Vite errors with `ENOENT ... node_modules/.deno/<pkg>@<ver>/...` after a
dependency change, the pre-bundle cache is stale. Wipe it and reboot:

```bash
rm -rf .vite node_modules .deno && bash dev.sh
```

If editing `vite.config.ts` seems to have no effect, restart the dev server by
hand. The watcher ignores config files because Vite's auto-restart wedges
the wrapper chain. `vite.config.ts` carries the details.
