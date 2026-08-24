# CapTP CLI

Call a capability from your shell, script CapTP with JSON, or drop pancake
into an agent via MCP. The binary links the same library as the Zig package.

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

In the devcontainer, skip both steps: `pancake` is already on `PATH` there, as
a link to the repo-root shim, and the shim runs `zig build` itself if the
binary is missing.

To install into a prefix that is already on your `PATH` (for example
`~/.local/bin`):

```sh
zig build -p "$HOME/.local"
pancake help
```

While iterating without installing: `zig build pancake -- <command> …` runs the
same binary through the build graph.

## Encrypted conversation

Native rooms traffic rides [iroh](https://www.iroh.computer/):

```sh
pancake app rooms-peer
```

The peer prints a locator. `reply --dm PEER` delivers through directory
introduction. Details are under [Sit in a room](#sit-in-a-room).

## Lab round-trip

`ocapn listen` binds loopback `tcp`, the testing transport: a cleartext
`host:port` with no identity proof.

This uses the same demo greeter as the Zig examples, a tiny actor that lives
only in the CLI adapter (`cli/ocapn/builtins.zig`) rather than in
`libpancake_*`. Its `greet` verb formats `Hello, <arg>`. Other verbs are listed
by `pancake help`.

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
#                         │      │       │     └─ arg, reply is "Hello, world"
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
| `pancake griddle …` | Deterministic simulator and timeline family |

```sh
pancake griddle run --scenario crossed-fetch --seed 7   # timeline as NDJSON
pancake griddle run --scenario partitioned-fetch --partition-at 1
pancake griddle run --scenario crossed-fetch --latency --seed 5
pancake griddle status
pancake griddle help
```

## CapTP lab (REPL)

The interactive lab is how you learn CapTP from the product CLI. On a TTY it
opens a fullscreen lab with the REPL in front: the conversation and the prompt
take most of the screen, and a CapTP instrument rail for exports, imports, and
answers sits beside them. Without a TTY it stays in line mode.

A locator is optional. Start empty and `dial` inside, or dial first. A REPL
or MCP `listen` binds and answers with its locator at once, then accepts
partners on a background thread; `close` stops it. The argv form below stays
a foreground accept loop:

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
fetch greeter                # yields a capability id N (see Imports rail)
call greeter greet world     # deliver by published name
call #N greet world          # same deliver, addressed by capability id
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

Environment variables tune the rest. `PANCAKE_REPL_QUIET=1` skips the one-line
workbench greeting, `PANCAKE_REPL_NO_MOUSE=1` turns mouse handling off, and
`PANCAKE_REPL_REDUCED_MOTION=1` shortens the flash and motion. Resize, reflow,
and footer tips are covered in-app.

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
`fetch` expose named fields (`locator`, `name`, `verb`, `args`), and tool calls
that do not match that generated schema are refused as invalid parameters.
After `zig build`, reload the MCP server in the host so the tools pick up the
new binary. For hosts where `pancake` is
already on `PATH`, a portable stub (no shim; set `PANCAKE_STATE` explicitly)
lives at [`docs/pancake-mcp.json`](pancake-mcp.json).

## Sit in a room

Room presence is `pancake app rooms-peer` (install alias `rooms-peer`). The peer
registers a giftable `dm` inbox so `reply --dm PEER` delivers via directory
introduction (same path as `demo-rooms-dm-iroh`). Native rooms-peer speaks iroh
and keyed-relay, not WebRTC: a first DM to a default browser tab cannot redeem
that locator, and the peer answers on the reply capability after the tab
messages first. Tabs that want to be introduced from native pick Via this server
(relay) in Settings, or open with `?dm=relay`. Deploy and locator details are in
[`apps/rooms/README.md`](../apps/rooms/README.md).

## Shell completion and scripting

```sh
eval "$(pancake completion bash)"   # or zsh | fish
```

A script picks its identity with `PANCAKE_STATE`, `PANCAKE_IDENTITY`, or
`--identity`, and should pass `--json` on every verb. `ocapn info` prints the
session summary: the front, the state path, and the partner's `abort_kind` and
`abort` reason when one was retained.

A `keyed-relay` locator names a peer that holds no listening socket (a
browser tab, or any process that registered its identity at a relay instead).
Its `rendezvous-relay` hint carries the dial route; `PANCAKE_RENDEZVOUS` is
the deployment fallback for a bare locator. It accepts `ws` or `wss`; WSS uses
the platform root store by default. A process that owns a private deployment
can set `PANCAKE_RELAY_CA_FILE` to a PEM root bundle; the CLI reads it once and
the relay initializer copies the bounded snapshot. The relay carries cleartext CapTP frames and does not
prove who answered. Native peers can seal that path with `noise-relay`. The
browser's managed WebSocket connector can accept the same sealed profile;
`web-peer-test` proves the native CLI can call it through a real Chromium peer
and a local WSS relay
([known limitations](boundaries.md#browser-reachability)):

```sh
export PANCAKE_RENDEZVOUS=wss://relay.example/relay
pancake --json ocapn call "ocapn://<key>.keyed-relay" greeter greet world
```

To be that peer rather than dial one, register instead of binding. Registration
and dialing may use different relay endpoints, so provide both. The listener
holds an inbound socket at the registration endpoint and prints a
`keyed-relay` locator carrying the advertised dial route:

```sh
pancake --json ocapn listen \
  --rendezvous wss://relay.example/register \
  --rendezvous-relay wss://relay.example/relay \
  --publish greeter
```

[ADR-0084](decisions/adr/ADR-0084-pancake-cli-product-boundary.md) records the
product boundary. [`shipped.md`](shipped.md) lists the commands that exist,
[`boundaries.md`](boundaries.md) records user-facing limits, and the
[`roadmap`](roadmap.md) owns unbuilt product work.
