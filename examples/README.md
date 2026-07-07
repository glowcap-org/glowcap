# pancake by example (Zig)

Runnable CapTP/OCapN walkthroughs. Each program carries its narrative in a `//!`
header and runs under `zig build examples` (and `zig build check`), so the prose
and the API calls can't drift from each other.

The chapters read top-down: chapter 01 is the surface an application rides,
chapter 02 widens it to the multi-connection `Host` tier, and chapters 03–05
then descend one layer at a time, ending at the raw engine.

| #  | Program                                                              | What it does                                                                                                                                                                                                                                 |
| -- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 01 | [`zig/01_connect_and_serve.zig`](zig/01_connect_and_serve.zig)       | The application surface over a real TCP socket: the host `listen`s, accepts, publishes by name, and `serve`s; the client `connect`s, fetches by name, `call`s, and switches on the settled outcome. One owning `driver.Connection` per side. |
| 02 | [`zig/02_introduce_and_redeem.zig`](zig/02_introduce_and_redeem.zig) | The capability pattern pancake exists for: a directory introduces the client to a service, the answer settles as a `.give`, `Host.redeem` turns it into a live reference, and the direct call leaves the directory out of the path. Three `driver.Host`s in one process.  |
| 03 | [`zig/03_actor_far_send.zig`](zig/03_actor_far_send.zig)             | Publish an actor, far-send to it across a paired session, and settle the promise. The `actors.Vat` pattern beneath chapter 01's `call`, and the one every networked application builds on.                                                   |
| 04 | [`zig/04_look_up_by_name.zig`](zig/04_look_up_by_name.zig)           | Fetch a capability through the bootstrap object using a swiss number — the machinery beneath fetch-by-name (the server side is one `registerBootstrapCap` call; the engine answers the `'fetch`).                                            |
| 05 | [`zig/05_call_a_remote_method.zig`](zig/05_call_a_remote_method.zig) | The raw engine: pair two peers, export and import by hand, and shuttle the deliver and resolve frames one explicit `step` at a time.                                                                                                         |

Full applications run in every binding, each built on the same small surface —
`connect`, `listen`, `fetch`, `publish`, `spawn`, `send`, `tell`, `serve`,
`close` — and that surface reads the same in every language:

- [`apps/rooms/`](apps/rooms/) — a capability-secure chat (real-time). A Deno
  server hosts a directory of rooms (`open`/`enter`, each returning a room
  capability, plus `list`/`watch` for discovery) and one client per language
  (Zig, Rust, Python, Racket, Deno). `zig build demo-rooms` joins one room over
  TCP and checks every member sees every message. It needs only `deno` and the
  always-built Zig client; the Python, Racket, and Rust clients join when their
  runtimes are present and are skipped with a note otherwise. It runs as a
  sibling of `check`, not as part of the hermetic gate.
- [`apps/tasks/`](apps/tasks/) — a capability-secure shared task board (CRUD +
  live state). A Deno server and one client per language (Zig, Rust, Python,
  Racket, Deno). `zig build demo-tasks` runs each client against one board: add
  a task, list, mark it done, confirm. It exercises request-response as
  promises, structured data over the wire, and live change notifications through
  capability callbacks, with the same runtime requirements as rooms.
- [`apps/tools/`](apps/tools/) — the capability showcase (AI agent harness). A
  Deno coordinator hands an agent capabilities to tools — attenuated to
  read-only, and revocable — and an agent in each language (Zig, Rust, Python,
  Racket, Deno) proves delegation, attenuation, and revocation over OCapN.
  `zig build demo-tools` runs each available agent against the coordinator;
  coordinator and agent are different languages on the wire, so the capability
  trio is real, not in-process.
- [`apps/accountability-on-pancake/`](apps/accountability-on-pancake/) — a
  signed-call accountability application: KERI-anchored identity, a signed
  Episode per capability invocation, and a Merkle transparency log, all above
  pancake's runtime over a real OCapN/TCP session. `zig build accountability`
  runs the native Zig walk (ridden by `zig build check`);
  `zig build demo-accountability` runs the Zig host with Deno and Python callers
  over the C ABI; `zig build accountability-three-party` proves a handoff-
  introduced caller is attributed, not the introducer.

Each demo binds an ephemeral port by default. Pin the port with `-Dport`
(`zig build demo-rooms -Dport=9099`), or add `-Dattach=true` to join a server
you already started on that port instead of spawning one, each app's README
shows the standalone server command the attach mode pairs with. (`demo-accountability`
is the exception: it rejects `-Dattach`, since each caller needs a fresh host.)

Each client is built the same way: it `fetch`es the server's capability by name,
`spawn`s a local actor (an inbox or watcher), and hands the server a reference to
it. There are no export-position numbers and no manual flush. The
request-response clients (tasks and tools) drive each call to its settled reply
and stop. The rooms clients have to watch their inbox for broadcasts that can
arrive at any time, so the higher-level bindings run `serve()` for that while the
native Zig client pumps `step` in an explicit loop.

Lower-level library mechanics:

- [`zig/readme_quick_start.zig`](zig/readme_quick_start.zig) — the README's
  Quick Start snippet, runnable: its `client` function is the snippet verbatim,
  paired with the minimal greeter host the snippet needs.
- [`zig/connect_explicit_buffers.zig`](zig/connect_explicit_buffers.zig) —
  chapter 01 one layer down: the caller owns the peer, its frame limit, and both
  buffers (`connectTcp` / `acceptTcp`), and observes the reply through the
  explicit promise idiom (`send`, `on`, `step`).
- [`zig/frame_view.zig`](zig/frame_view.zig) — moving an owned `Frame` into a
  borrowed `FrameView`.
- [`c/frame_view.c`](c/frame_view.c) — the same over the C ABI.
- [`c/context_alloc.c`](c/context_alloc.c) — C-owned allocation policy through
  `PancakeContext`.
- [`c/echo_peer.c`](c/echo_peer.c) — a complete in-process event loop in pure C:
  two peers exchange frames through memory, the client fetches a published
  capability with `pancake_peer_send_bootstrap_fetch`, calls it, and reads the
  typed reply. This is the sans-io primitive for a host that owns its own loop;
  a consumer that just wants to dial, fetch, and call reaches instead for the
  owning `PancakeTcpSession` (ADR-0062), worked end-to-end against a runtime
  host in
  [`test/c_abi/tcp_session_test.zig`](../test/c_abi/tcp_session_test.zig).
- [`c/compose_transports.c`](c/compose_transports.c) — linking the à-la-carte C
  ABI archives together: `libpancake_ocapn` with the tcp and inproc transport
  archives composed and resolved in one consumer (ADR-0059).
