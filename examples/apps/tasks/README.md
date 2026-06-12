# tasks — a capability-secure shared task board, in five languages at once

This is a small, real application built on pancake actors. A task board runs as
a server; clients connect, add tasks, mark them done, and see changes in real
time. What makes it worth reading is not the task board — it is *how* the board
works, and that clients written in Zig, Rust, Python, Racket, and Deno manage the same
board at the same time, none of them aware of the others' languages.

Run the whole thing with one command:

```sh
zig build demo-tasks
```

That starts a Deno-hosted board and runs one client per available language.
Each client adds a task, lists the board, marks its task done, and confirms the
change. When they all succeed you will see a transcript per language and a final
line saying every client completed a round trip.

The only runtime the demo requires is `deno`, which hosts the board and runs the
orchestrator, plus the Zig client, which `zig build` always builds. Python,
Racket, and Rust each join only when their runtime (`python3`, `racket`, `cargo`)
is on PATH; the demo reports any language it skipped rather than failing. It is a
sibling of `zig build check`, not part of the hermetic gate.

By default the demo binds an ephemeral port; pin it with
`zig build demo-tasks -Dport=9099`. To run the demo's clients against a board
you already started yourself (the fixed-port server below), add attach mode:
`zig build demo-tasks -Dport=9099 -Dattach=true` joins your server instead of
spawning its own, and leaves it running when the demo ends.

## Use it interactively

Start the server in one terminal:

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/tasks/deno/server.ts 9099
```

It prints `TASKS-SERVER-LISTENING 9099`. Then open another terminal and manage
tasks:

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/tasks/deno/board.ts 127.0.0.1 9099
```

Type `add buy groceries`, `list`, `done 1`, or `quit`. Open more terminals to
see live updates arrive through capability callbacks — every connected watcher
sees every change as it happens, with no polling.

## What this shows that rooms doesn't

Rooms is a chat — pub/sub with capability callbacks. Tasks shows a different
pattern:

- **CRUD with capability security.** `add` creates state, `done` mutates it,
  `list` queries it. No REST endpoints, no auth middleware. The capability is
  the authorization.
- **Request-response as a promise.** `add("buy groceries")` returns the new
  task's ID as a fulfilled promise. This is a real RPC, not a fire-and-forget
  message. In Deno: `const id = await board.add("buy groceries")`. In Python:
  `task_id = await board.add("buy groceries")`. In Rust:
  `let id = board.add("buy groceries").await?`.
- **Structured data over the wire.** A task is `[id, text, completed]` — a list
  of typed values, not a string. The board returns a list of tasks as a list of
  lists. Every language parses it into its own native type.
- **Live updates through capability callbacks.** When any client changes the
  board, every watcher's callback fires with the full current state. No polling
  loop, no WebSocket subscription endpoint, no message queue to drain. The board
  holds a live capability to your watcher and calls it.

Together, rooms and tasks cover the two most common patterns people build:
pub/sub with push notifications, and CRUD with live state synchronization. Both
work across languages, both are secured by capabilities, and both read naturally
in every binding.

## The idea: the capability is the permission

In an HTTP world, this application needs:
- An API server with REST endpoints
- Authentication (tokens, sessions, OAuth)
- Authorization middleware (who can add? who can mark done?)
- A WebSocket or SSE layer for live updates
- Client libraries that wire all of this together

With OCapN capabilities:
- A board actor with four methods
- A watcher actor the client publishes
- The client hands the board a capability to its watcher
- The capability *is* the identity — the board knows who you are because it
  holds your capability

No tokens. No middleware. No separate push layer. The board calls you back
because you gave it a live reference to your watcher, the same way you call the
board because the board gave you a reference to itself.

## Layout

```
examples/apps/tasks/
├── deno/protocol.ts      the shared wire contract: a capability name and five verbs
├── deno/server.ts         the board server (multi-connection, capability callbacks)
├── deno/task_client.ts    the TaskBoard client (the OCapN layer) in Deno
├── deno/client.ts         the one-shot demo client in Deno
├── deno/board.ts          the interactive terminal client
├── python/task_client.py + client.py    the same, in Python
├── racket/task-client.rkt + client.rkt  the same, in Racket
├── rust/board.rs + client.rs            the same, in Rust (its own crate)
├── zig/client.zig         the same in native Zig, on the connection driver
└── demo.ts                the orchestrator `zig build demo-tasks` runs
```

Each language has a `TaskBoard` client — the small layer that knows about OCapN
(publish a watcher, hand the board a capability to it, drive the vat) — and a
thin app on top of it. The app reads the same in every language because each
`TaskBoard` exposes its own runtime's native async shape:

| Language | Add a task | List tasks | Mark done |
| --- | --- | --- | --- |
| Deno | `await board.add(text)` | `await board.list()` | `await board.done(id)` |
| Python | `await board.add(text)` | `await board.list()` | `await board.done(id)` |
| Racket | `(board-add b text)` | `(board-list b)` | `(board-done b id)` |
| Rust | `board.add(text).await?` | `board.list().await?` | `board.done(id).await?` |

Reading any two side by side shows how little the actor model changes from
language to language — and how much boilerplate disappears compared to the
HTTP version of the same application.

## Where the board could go next

The server keeps tasks in memory and broadcasts every change to every watcher.
It does not yet attenuate (a read-only board handle that can `list` and `watch`
but not `add` or `done`) or persist tasks across restarts. Attenuation and
revocation on this exact capability model are shown end-to-end in the sibling
[`tools`](../tools/) showcase, where a read-only view is an actor that forwards
only the safe verbs. Wiring a read-only board handle is a few lines and a good
next exercise.
