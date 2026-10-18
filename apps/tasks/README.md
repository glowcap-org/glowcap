# Tasks

Tasks is a shared board built on glowcap. A board holds lists and a list holds
tasks. The server saves all of it in Loam, so the board, its lists, and every
task come back after a restart, reached by the same name.

Try it in two terminals. Build and start the server on a directory of its own:

```sh
mkdir -p apps/tasks/.data
zig build tasks-server -- --data=apps/tasks/.data --port=9099
```

It prints `TASKS-SERVER-LISTENING 9099 <name>`. The name is a secret: anyone
who has it can open the board. Open the board with it:

```sh
deno run --allow-ffi --allow-read --allow-net \
  apps/tasks/deno/board.ts 127.0.0.1 9099 <name>
```

Use `add buy groceries`, `list`, `done 0`, or `quit`. A new board starts with a
**To do** list and a **Done** list, and `done` moves a task from the first to
the second. Stop the server, start it again on the same directory, and the
same name opens the same board.

## The board's capabilities

The server publishes the board under its secret name. Every list and task is
its own capability, reached from the board:

- The board answers `lists()` with how many lists it holds, and `list(i)` with
  a capability for one of them.
- A list answers `name()`, `count()`, and `task(i)`, which returns a
  capability for one task.
- A task answers `text()`.

Changes go through `mutate(sequence, verb, ...)`, with a sequence number the
client takes from `mutation-sequence()` first. A client that retries a change
after a lost reply sends the same number, and the change happens once.

- `mutate(n, "add", text)` on a list adds a task to its end and replies with
  the new task's capability. A board holds up to 16 lists, a list up to 256
  tasks, and a task's text up to 4096 bytes. A value past a limit is refused
  and nothing changes.
- `mutate(n, "add-list", name)` on the board adds a list to its end and
  replies with the new list's capability. The server adds **To do** and
  **Done** this way when a board is new.
- `mutate(n, "move", task, list)` moves a task this list holds to the end of
  another list. The task is named by its capability, so a move never acts on
  a task that another client's change shifted into the same position. The
  task and both lists change in one save, so a crash can't leave the task in
  both lists or neither.

A client watches the board with `mutate(n, "observe")` on the board, which
replies with a receiver and a canceller. The receiver's `poll(cursor)` says
whether anything on the board changed since that cursor and hands back a new
one, in the reply that
[Loam observation](../../docs/loam/access-observation.md) describes. A board
admits 32 watchers at once, and a watcher outlives the client that made it, so
a client calls `cancel()` on the canceller when it stops watching. The receiver
has its own `durable-name()`, so a client that comes back after a restart
fetches it by that name, polls with its last cursor, and learns that the board
changed while it was away.

The board's owner can share any list or task with fewer permissions, through
the methods every Loam resource answers:

- `derive(n, scope, policy, permissions, bounds, depth)` returns a new
  capability. It takes its number from the board's `derivation-sequence()`.
  The scope is `object` for one list or task, or `subtree` for it and
  everything under it, including tasks added later.
- A read-only share reads and is refused every change. Its `durable-name()`
  keeps working after a restart, and a shared task stays reachable after it
  moves to another list.
- `derive-managed` returns the share together with a control. The control's
  `mutate(n, "revoke", revision)` takes the share away from everything under
  it, while the owner's own access is untouched.

## Try every binding

```sh
zig build demo-tasks
```

The demo starts the server on a fresh directory, then has each available
language client watch the board, add a task, move it to **Done**, read both
lists back, and check that its watcher saw the change.
Deno and Zig are required. Python, Racket, and Rust join when installed. The
common port option is documented in the
[app index](../README.md#how-the-cross-language-demos-run).

Each binding presents the same calls in its own style:

| Language | Watch | Add | Mark done | Read both lists |
| --- | --- | --- | --- | --- |
| Deno | `await board.watch()` | `await board.add(text)` | `await board.done(task)` | `await board.lists()` |
| Python | `await board.watch()` | `await board.add(text)` | `await board.done(task)` | `await board.lists()` |
| Racket | `(board-watch b)` | `(board-add b text)` | `(board-done b task)` | `(board-lists b)` |
| Rust | `board.watch().await?` | `board.add(text).await?` | `board.done(&task).await?` | `board.lists().await?` |

Adding returns the new task, and marking done takes that task. A watcher's
`changed()` (`watcher-changed?` in Racket) says whether the board changed
since its last look, and `stop()` (`watcher-stop`) cancels it.

The server lives under [`zig/`](zig/), beside the Zig client. The other
directories hold the matching Deno, Python, Racket, and Rust clients, and
[`demo.ts`](demo.ts) coordinates the cross-language run.

`zig build tasks-app-test` runs the server over TCP with a temporary store. It
adds and moves tasks, checks that an oversized task is refused without a
change, and reopens the store to check that everything is still there. It also
checks that shares keep working after a restart and stop at revocation, and
that a watcher catches up on a change made while the server was down. It is
part of `zig build check`.
