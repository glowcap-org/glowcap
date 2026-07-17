# CapTP CLI

Call a capability from your shell. Script CapTP with JSON. Drop pancake into an
agent via MCP. Same library as the Zig package, not a second protocol stack.

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

Same demo greeter as the README / Zig examples: a tiny actor that lives only
in the CLI adapter (`cli/ocapn/mod.zig`), not in `libpancake_*`. Verb `greet`
formats `Hello, <arg>`; `cowsay`, `pancakesay`, and `goblinsay` return speech
balloons (cow, faced pancake stack, or a friendly goblin doodle) for the same
string arg.

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

CLI built-ins (demo actors only): `greeter` (`greet`, `cowsay`, `pancakesay`,
`goblinsay`) and `echo` (verb `echo`, returns its arg unchanged). CapTP itself
does not hard-code either.

`Ctrl+C` / `SIGTERM` stops a waiting or serving `listen` cleanly (exit 0).

## Is it up?

Handshake only (`ocapn probe`). Start a **fresh** listen: a prior `--publish`
peer is already gone after one partner.

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
pancake griddle status   # brand locked; runtime not implemented
pancake griddle help
```

## CapTP lab (REPL)

The interactive lab is how you learn CapTP from the product CLI. On a TTY it
opens a fullscreen REPL-primary lab: conversation + prompt take most of the
screen, with a CapTP instrument rail (exports / imports / answers) beside it.
Without a TTY it stays in line mode.

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

Inside the lab (workbench by default. CapTP verbs, rail, transcript):

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
Tab / Shift-Tab              # cycle completions (TTY); Enter accepts, Esc dismisses menu / cancels wait
↑ / ↓                        # command history at the prompt
Ctrl-O                       # transcript browse (j/k, PgUp/PgDn, g/G)
F1                           # modal key help
wheel / Shift↑↓ / PgUp·PgDn  # scroll (Ctrl-Home/End jump)
[↓ jump] button              # when scrolled up, click to return to live
click                        # expand/collapse long blocks; menu accept
Ctrl-click                   # open/insert ocapn:// or https:// link
drag                         # character select across lines → copy on release (OSC 52)
Shift-drag                   # terminal-native select (SSH/tmux fallback)
Ctrl-y                       # re-copy last in-app selection
Ctrl-p / Ctrl-t              # cycle panel focus (prompt / transcript / rail)
quit
```

The lab tracks terminal resizes (SIGWINCH) and reflows (side rail ≥80 cols;
narrow terminals stack CapTP counts above the REPL). For the whole alt-screen
lifetime, CLI diagnostics divert into the transcript (never stderr beside the
cursor). Idle frames non-blockingly pump an open CapTP session so rail counts
stay live. Each successful verb appends a CapTP gloss; the prompt dock shows a
footer tip (`guide` for the optional walkthrough). `PANCAKE_REPL_QUIET=1`
skips the one-line workbench greeting. `PANCAKE_REPL_NO_MOUSE=1` disables
mouse; `PANCAKE_REPL_REDUCED_MOTION=1` shortens flash/motion.

## Agent control plane

```sh
pancake mcp --tools default
# catalogs: default | full | readonly; discover tools via MCP tools/list
```

This repo wires CapTP MCP into Cursor and Claude via the root [`pancake`](../pancake)
shim (`./pancake mcp --tools default`; see `.cursor/mcp.json` and `.mcp.json`;
requires `zig build` first). Stdio framing is newline-delimited JSON-RPC.
Tool results match argv `--json` (including `{"ok":false,"error":…}` on
failure; `isError` mirrors exit). Default state is
`.local/pancake-mcp-state` (cwd-relative) so it does not share a human
argv/REPL identity. Host/listen stays argv-only. Discover tools with `tools/list`. Portable stub
when `pancake` is on `PATH` (no shim: set `PANCAKE_STATE` explicitly):
[`docs/examples/pancake-mcp.json`](examples/pancake-mcp.json).

## Sit in a room

Room presence is `pancake app rooms-peer` (install alias `rooms-peer`). The peer
registers a giftable `dm` inbox so `reply --dm PEER` delivers via directory
introduction (same path as `demo-rooms-dm-iroh`). Deploy and locator details:
[`examples/apps/rooms/README.md`](../examples/apps/rooms/README.md).

## Shell completion

```sh
eval "$(pancake completion bash)"   # or zsh | fish
```

Identity: `PANCAKE_STATE`, `PANCAKE_IDENTITY`, or `--identity`. Prefer `--json`
when scripting. Session summary: `ocapn info` (front, path, partner
`abort_kind`/`abort` when retained). MCP tool schemas project front-applicable
flags and positionals from the CapTP registry (`--repl` stays argv-only).
`call` / `tell` / `fetch` expose named fields (`locator`, `name`, `verb`,
`args`); a legacy positional `args` array still works. After `zig build`, reload
the MCP server in the host so tools pick up the new binary.

Boundary: [ADR-0084](decisions/adr/ADR-0084-pancake-cli-product-boundary.md).
Edges: [`shipped.md`](shipped.md), [`boundaries.md`](boundaries.md).
