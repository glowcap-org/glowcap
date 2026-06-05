# pancake by example (Zig)

Runnable CapTP/OCapN walkthroughs. Each program carries its narrative in a `//!`
header and runs under `zig build examples` (and `zig build check`), so the prose
and the API calls can't drift from each other.

| # | Program | What it does |
| --- | --- | --- |
| 01 | [`zig/01_call_a_remote_method.zig`](zig/01_call_a_remote_method.zig) | Pair two peers; one calls a method on the other and reads the answer. |
| 02 | [`zig/02_look_up_by_name.zig`](zig/02_look_up_by_name.zig) | Fetch a capability through the bootstrap object using a swiss-number (the server side is just `registerBootstrapCap` — the runtime answers the `'fetch`). |

Lower-level library mechanics:

- [`zig/frame_view.zig`](zig/frame_view.zig) — owned `Frame` → borrowed `FrameView`.
- [`c/frame_view.c`](c/frame_view.c) — the same over the C ABI.
