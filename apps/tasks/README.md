# Tasks

Tasks is a shared board built on pancake. Clients add work, mark it done, list
the board, and receive changes as they happen.

Try it in two terminals. Start the server:

```sh
deno run --allow-ffi --allow-read --allow-net \
  apps/tasks/deno/server.ts 9099
```

Then open the board:

```sh
deno run --allow-ffi --allow-read --allow-net \
  apps/tasks/deno/board.ts 127.0.0.1 9099
```

Use `add buy groceries`, `list`, `done 1`, or `quit`. Open another client to
see updates arrive without polling.

## Where the capabilities are

The server publishes one board capability with four operations:

- `add(text)` creates a task and returns its ID.
- `done(id)` marks a task complete.
- `list()` returns the current tasks as structured values.
- `watch(callback)` asks the board to send later snapshots to a callback.

There are two grants here. Receiving the board capability grants access to the
whole board API. Passing a callback capability to `watch` grants the board
permission to send updates back to that client. The callback identifies where
to deliver updates; it does not authenticate the caller or narrow what the
caller may do.

The board currently gives every holder the same access. It has no read-only
view, and its in-memory tasks disappear when the server stops. The
[`tools`](../tools/) app shows how a capability can be wrapped to expose fewer
operations or be revoked.

## Try every binding

```sh
zig build demo-tasks
```

The demo starts a fresh board, then has each available language client add,
list, and complete a task. Deno and Zig are required; Python, Racket, and Rust
join when installed. The common port and attach options are documented in the
[app index](../README.md#how-the-cross-language-demos-run).

Each binding presents the same calls in its own style:

| Language | Add | List | Complete |
| --- | --- | --- | --- |
| Deno | `await board.add(text)` | `await board.list()` | `await board.done(id)` |
| Python | `await board.add(text)` | `await board.list()` | `await board.done(id)` |
| Racket | `(board-add b text)` | `(board-list b)` | `(board-done b id)` |
| Rust | `board.add(text).await?` | `board.list().await?` | `board.done(id).await?` |

The protocol and Deno server live under [`deno/`](deno/). The other directories
contain matching Python, Racket, Rust, and Zig clients; [`demo.ts`](demo.ts)
coordinates the cross-language run.
