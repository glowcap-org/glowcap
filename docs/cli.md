# CapTP CLI

Call a capability from your shell, script CapTP with JSON, or drop pancake
into an agent via MCP. The binary holds the same library as the Zig package,
not a second protocol stack.

Flags, CapTP verbs, exit codes, environment, and wait budgets live in the
binary: `pancake help` (and `help ocapn`, `-h` on any command).

## Install

From the repository root:

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
pancake help
```

`zig build` installs `pancake` (and a thin `rooms-peer` shim) under `zig-out/bin`.
Put that directory on your `PATH` once per shell, then every example below is
just `pancake …`.

To install into a prefix that is already on your `PATH` (for example
`~/.local/bin`):

```sh
zig build -p "$HOME/.local"
pancake help
```

While iterating without installing: `zig build pancake -- <command> …` runs the
same binary through the build graph.

## Round-trip in two terminals

This uses the same demo greeter as the README and the Zig examples, a tiny actor
that lives only in the CLI adapter (`cli/ocapn/builtins.zig`) rather than in
`libpancake_*`. Its `greet` verb formats `Hello, <arg>`. Its `cowsay`,
`pancakesay`, and `goblinsay` verbs return a speech balloon for the same string
argument: a cow, a faced pancake stack, or a friendly goblin doodle.

Each peer needs its own identity. Use a separate `PANCAKE_STATE` per terminal.

**Terminal A.** Mint an identity, listen, publish the greeter (`--publish`
accepts one partner, then exits):

```sh
export PANCAKE_STATE=/tmp/pancake-a
pancake --json init
pancake --json ocapn listen --publish greeter
```

```text
{"ok":true,"path":"/tmp/pancake-a/identity","identity":"…"}
{"ok":true,"locator":"ocapn://127.0.0.1%3A46659.tcp"}
pancake: listening; will publish greeter when a partner connects (Ctrl-C to stop)
```

The process then blocks on accept: that is the happy path, not a hang. Greeter
is published only after Terminal B dials. `%3A` is a percent-encoded `:`. The
designator is `127.0.0.1:46659` (standard OCapN peer URI form
`ocapn://<designator>.tcp`). Paste A's locator as printed.

**Terminal B.** Mint, then one answered call:

```sh
export PANCAKE_STATE=/tmp/pancake-b
pancake --json init

LOC='ocapn://127.0.0.1%3A46659.tcp'   # paste A's locator
pancake --json ocapn call "$LOC" greeter greet world
#                         │      │       │     └─ arg  → reply "Hello, world"
#                         │      │       └─ verb
#                         │      └─ published name (--publish greeter)
#                         └─ peer
```

```text
{"ok":true,"value":"Hello, world"}
```

Change the arg, change the reply:

```sh
pancake --json ocapn call "$LOC" greeter greet pancake \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["value"])'
# prints: Hello, pancake
```

The built-ins are demo actors only: `greeter`, with `greet`, `cowsay`,
`pancakesay`, and `goblinsay`, and `echo`, whose `echo` verb returns its arg
unchanged. CapTP itself hard-codes neither.

`Ctrl+C` / `SIGTERM` stops a waiting or serving `listen` cleanly (exit 0).

## Is it up?

`ocapn probe` runs the handshake and nothing else. Start a **fresh** listen for
it, because a prior `--publish` peer is already gone after one partner.

```sh
# terminal A
export PANCAKE_STATE=/tmp/pancake-a
pancake --json ocapn listen --publish greeter

# terminal B: paste the new locator
export PANCAKE_STATE=/tmp/pancake-b
pancake --json ocapn probe "$LOC"
```

```text
{"ok":true}
```

## Command map

| Command | Role |
|---------|------|
| `pancake ocapn …` | CapTP verbs |
| `pancake repl` | CapTP lab (TTY workbench / line mode) |
| `pancake mcp` | Agent control plane |
| `pancake app rooms-peer` | Room presence and DM-by-introduction (`reply --dm PEER`) |
| `pancake griddle …` | Simulator / timeline family (**placeholder**) |

```sh
pancake griddle status   # name reserved; runtime not implemented
pancake griddle help
```

## CapTP lab (REPL)

The interactive lab is how you learn CapTP from the product CLI. On a TTY it
opens a fullscreen lab with the REPL in front: the conversation and the prompt
take most of the screen, and a CapTP instrument rail for exports, imports, and
answers sits beside them. Without a TTY it stays in line mode.

A locator is optional. Start empty and `dial` inside, or dial first (`listen` stays argv-only):

```sh
# terminal A
export PANCAKE_STATE=/tmp/pancake-a
pancake --json ocapn listen --publish greeter

# terminal B
export PANCAKE_STATE=/tmp/pancake-b
pancake repl                 # sessionless lab, then dial inside
# or: pancake repl "$LOC"    # dial first (same as ocapn dial --repl)
```

Inside the lab (the workbench view by default, with CapTP verbs, the instrument
rail, and the transcript):

```text
help                         # everyday verbs
help captp                   # CapTP noun map (+ light tip: guide)
?                            # short workbench tip (or guide coach while guided)
guide                        # optional CapTP walkthrough (toggle); guide exit leaves
dial ocapn://127.0.0.1%3A….tcp   # no quotes; listen is argv-only (blocking)
fetch greeter                # mints an import N (see Imports rail)
call greeter greet world     # deliver by published name
call #N greet world          # same deliver, addressed by import position
close                        # tear down the session (no library "reset"; close + redial)
tour exports                 # point at a CapTP pane
focus                        # quiet/focus mode (collapse rail to counts)
# TTY only: call/fetch/tell/publish settle in the background; a spinner line
# appears in the transcript; the prompt stays usable. CapTP verbs queue FIFO;
# tour/help/focus/guide run immediately. Esc cancels the active wait (#0 is bootstrap).
quit
```

`Tab` completes, `F1` shows the full key map, and mouse, selection, scrolling,
and clipboard behavior are documented in-app, so this page does not repeat
them.

The lab keeps up with your terminal. It follows resizes (SIGWINCH) and reflows:
the side rail needs at least 80 columns, and a narrower terminal stacks the
CapTP counts above the REPL. While the alt screen is up, CLI diagnostics go into
the transcript instead of to stderr beside the cursor, so nothing prints over
what you are reading. Idle frames pump an open CapTP session without blocking,
which is what keeps the rail counts live. Each successful verb appends a CapTP
gloss, and the prompt dock carries a footer tip pointing at `guide`, the
optional walkthrough.

Environment variables tune the rest. `PANCAKE_REPL_QUIET=1` skips the one-line
workbench greeting, `PANCAKE_REPL_NO_MOUSE=1` turns mouse handling off, and
`PANCAKE_REPL_REDUCED_MOTION=1` shortens the flash and motion.

## Agent control plane

```sh
pancake mcp --tools default
# catalogs: default | full | readonly; discover tools via MCP tools/list
```

This repository wires CapTP MCP into Cursor and Claude through the root
[`pancake`](../pancake) shim, which runs `./pancake mcp --tools default`. Run
`zig build` first; the wiring itself lives in `.cursor/mcp.json` and
`.mcp.json`. Stdio framing is
newline-delimited JSON-RPC. Tool results match argv `--json`, including
`{"ok":false,"error":…}` on failure, and `isError` mirrors the exit code.
MCP state defaults to `.local/pancake-mcp-state`, relative to the working
directory, so an agent never shares a human argv/REPL identity. Hosting stays
argv-only: `listen` parks on accept, so it is never an MCP tool.

The tool schemas are projected from the CapTP registry, one front-applicable
flag and positional at a time (`--repl` stays argv-only). `call`, `tell`, and
`fetch` expose named fields (`locator`, `name`, `verb`, `args`); a legacy
positional `args` array still works. After `zig build`, reload the MCP server
in the host so the tools pick up the new binary. For hosts where `pancake` is
already on `PATH`, a portable stub (no shim; set `PANCAKE_STATE` explicitly)
lives at [`docs/examples/pancake-mcp.json`](examples/pancake-mcp.json).

## Sit in a room

Room presence is `pancake app rooms-peer` (install alias `rooms-peer`). The peer
registers a giftable `dm` inbox so `reply --dm PEER` delivers via directory
introduction (same path as `demo-rooms-dm-iroh`). Deploy and locator details are
in [`apps/rooms/README.md`](../apps/rooms/README.md).

## Shell completion and scripting

```sh
eval "$(pancake completion bash)"   # or zsh | fish
```

A script picks its identity with `PANCAKE_STATE`, `PANCAKE_IDENTITY`, or
`--identity`, and should pass `--json` on every verb. `ocapn info` prints the
session summary: the front, the state path, and the partner's `abort_kind` and
`abort` reason when one was retained.

[ADR-0084](decisions/adr/ADR-0084-pancake-cli-product-boundary.md) records the
product boundary. [`shipped.md`](shipped.md) lists the commands that exist,
[`boundaries.md`](boundaries.md) records user-facing limits, and the
[`roadmap`](roadmap.md) owns unbuilt product work.
