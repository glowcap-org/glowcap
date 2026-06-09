# pancake by example (Zig)

Runnable CapTP/OCapN walkthroughs. Each program carries its narrative in a `//!`
header and runs under `zig build examples` (and `zig build check`), so the prose
and the API calls can't drift from each other.

| # | Program | What it does |
| --- | --- | --- |
| 01 | [`zig/01_call_a_remote_method.zig`](zig/01_call_a_remote_method.zig) | Pair two peers; one calls a method on the other and reads the answer. |
| 02 | [`zig/02_look_up_by_name.zig`](zig/02_look_up_by_name.zig) | Fetch a capability through the bootstrap object using a swiss-number (the server side is just `registerBootstrapCap` — the engine answers the `'fetch`). |
| 03 | [`zig/03_actor_far_send.zig`](zig/03_actor_far_send.zig) | Publish an actor, far-send to it across a paired session, and settle the promise. The `actors.Vat` pattern every networked application builds on. |

Full applications across every binding, each built on the same small surface —
`connect`, `fetch`, `publish`, `spawn`, `send`, `serve`, `close` — that reads the
same in every language:

- [`apps/rooms/`](apps/rooms/) — a capability-secure chat room (real-time). A Deno
  server and one client per language (Zig, Rust, Python, Racket, Deno). `zig build
  rooms` joins one room over TCP and checks every member sees every message. It
  needs only `deno` and the always-built Zig client; the Python, Racket, and Rust
  clients join when their runtimes are present and are skipped with a note
  otherwise. A sibling of `check`, not part of the hermetic gate.
- [`apps/tasks/`](apps/tasks/) — a capability-secure shared task board (CRUD +
  live state). A Deno server and one client per language (Zig, Rust, Python,
  Racket, Deno). `zig build tasks` runs each client against one board: add a task,
  list, mark it done, confirm. Request-response as promises, structured data over
  the wire, and live change notifications through capability callbacks. Same
  runtime requirements as rooms.
- [`apps/tools/`](apps/tools/) — the capability showcase (AI agent harness). A Deno
  coordinator hands an agent capabilities to tools — attenuated to read-only, and
  revocable — and an agent in each language (Zig, Rust, Python, Racket, Deno)
  proves delegation, attenuation, and revocation over OCapN. `zig build tools` runs
  each available agent against the coordinator; coordinator and agent are different
  languages on the wire, so the capability trio is real, not in-process.

A client in each is published the same way: a client `fetch`es the server's
capability by name, `spawn`s a local actor (an inbox/watcher), and hands the
server a reference to it — no export-position numbers, no manual flush, no
hand-rolled serve loop.

Lower-level library mechanics:

- [`zig/frame_view.zig`](zig/frame_view.zig) — moving an owned `Frame` into a borrowed `FrameView`.
- [`c/frame_view.c`](c/frame_view.c) — the same over the C ABI.
- [`c/context_alloc.c`](c/context_alloc.c) — C-owned allocation policy through
  `PancakeContext`.
