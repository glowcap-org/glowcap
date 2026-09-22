# CapTP CLI

Call a capability from your shell, script CapTP with JSON, or drop glowcap
into an agent via MCP. The binary links the same library as the Zig package.

Flags, CapTP verbs, exit codes, environment, and wait budgets live in the
binary: `glowcap help` (and `help ocapn`, `-h` on any command).

## Install

For the core CLI while developing from the repository root:

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
glowcap help
```

`zig build` installs the core `glowcap` CLI under `zig-out/bin`. The complete
installation adds the Rooms runtimes, prepared browser assets, and skills.
Contributors can install it with the checkout launcher:

```sh
./glowcap install --prefix "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
```

Alternatively, install a complete platform archive through the
[host guide](../apps/rooms/host.md). The installer verifies its generated
inventory, stores an immutable content-addressed generation, and atomically
selects the `bin/glowcap` symlink. It refuses an unrelated executable and keeps
older generations for running processes.

In the devcontainer, `glowcap` on PATH is a link to the checkout's `./glowcap`
development launcher. It runs the complete product in `zig-out/product`,
building it only when absent. Bootstrap uses `rooms-build` with
`-Doptimize=ReleaseSafe -Dcpu=baseline`; Linux can build through this checkout's
devcontainer, while macOS uses its local toolchain. Once prepared, ordinary
commands need neither the compiler nor the devcontainer. After source edits,
run `zig build rooms-build -Doptimize=ReleaseSafe -Dcpu=baseline` in the build
environment to update the product. `./glowcap install` installs that prepared
product. An installed binary never builds source or downloads components.

On Linux, `./glowcap apps rooms deployment up` uses the checkout's prepared
product to build its container image unless an image source is explicit.
The [deployment guide](../apps/rooms/web/deploy/README.md) explains
state ownership and how installed releases select images.

While iterating without installing: `zig build glowcap -- <command> …` runs the
same binary through the build graph.

## Encrypted conversation

Rooms sessions use [iroh](https://www.iroh.computer/) by default.
`glowcap apps rooms session` operates one durable workspace;
`reply --dm PEER` delivers through directory introduction.
[Sit in a room](#sit-in-a-room) shows startup and message handling.
The generic `ocapn` commands, REPL, and MCP currently register TCP and configured
relay routes, not iroh or WebRTC. Their Zig Session adapter's multiplexed
transport support remains [a known boundary](boundaries.md#transports-and-peer-identity).

## Lab round-trip

`ocapn listen` binds loopback `tcp`, the testing transport: a cleartext
`host:port` with no identity proof.

This uses the same demo greeter as the Zig examples, a tiny actor that lives
only in the CLI adapter (`cli/ocapn/builtins.zig`) rather than in
`libglowcap_*`. Its `greet` verb formats `Hello, <arg>`. Other verbs are listed
by `glowcap help`.

Each peer needs its own identity. Use a separate `GLOWCAP_STATE` per terminal.

**Terminal A.** Mint an identity, listen, publish the greeter (`--publish`
accepts one partner, then exits):

```sh
export GLOWCAP_STATE=/tmp/glowcap-a
glowcap --json init
glowcap --json ocapn listen --publish greeter
```

```text
{"ok":true,"path":"/tmp/glowcap-a/identity","identity":"…"}
{"ok":true,"locator":"ocapn://127.0.0.1%3A46659.tcp"}
glowcap: listening; will publish greeter when a partner connects (Ctrl-C to stop)
```

The process then blocks on accept: that is the happy path, not a hang. Greeter
is published only after Terminal B dials. `%3A` is a percent-encoded `:`. The
designator is `127.0.0.1:46659` (standard OCapN peer URI form
`ocapn://<designator>.tcp`). Paste A's locator as printed.

**Terminal B.** Mint, then one answered call:

```sh
export GLOWCAP_STATE=/tmp/glowcap-b
glowcap --json init

LOC='ocapn://127.0.0.1%3A46659.tcp'   # paste A's locator
glowcap --json ocapn call "$LOC" greeter greet world
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
glowcap --json ocapn call "$LOC" greeter greet glowcap \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["value"])'
# prints: Hello, glowcap
```

The built-ins are demo actors only: `greeter`, with `greet`, `cowsay`,
`glowcapsay`, and `goblinsay`, and `echo`, whose `echo` verb returns its arg
unchanged. CapTP itself hard-codes neither.

`Ctrl+C` / `SIGTERM` stops a waiting or serving `listen` cleanly (exit 0).

## Is it up?

`ocapn probe` runs the handshake and nothing else. Start a **fresh** listen for
it, because a prior `--publish` peer is already gone after one partner.

```sh
# terminal A
export GLOWCAP_STATE=/tmp/glowcap-a
glowcap --json ocapn listen --publish greeter

# terminal B: paste the new locator
export GLOWCAP_STATE=/tmp/glowcap-b
glowcap --json ocapn probe "$LOC"
```

```text
{"ok":true}
```

## Command map

| Command | Role |
|---------|------|
| `glowcap ocapn …` | CapTP verbs |
| `glowcap repl` | CapTP lab (TTY workbench / line mode) |
| `glowcap mcp` | Agent control plane |
| `glowcap apps rooms session` | Room presence and DM-by-introduction (`reply --dm PEER`) |
| `glowcap griddle …` | Deterministic simulator and timeline family |

```sh
glowcap griddle run --scenario crossed-fetch --seed 7   # timeline as NDJSON
glowcap griddle run --scenario partitioned-fetch --partition-at 1
glowcap griddle run --scenario crossed-fetch --latency --seed 5
glowcap griddle status
glowcap griddle help
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
export GLOWCAP_STATE=/tmp/glowcap-a
glowcap --json ocapn listen --publish greeter

# terminal B
export GLOWCAP_STATE=/tmp/glowcap-b
glowcap repl                 # sessionless lab, then dial inside
# or: glowcap repl "$LOC"    # dial first (same as ocapn dial --repl)
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

Environment variables tune the rest. `GLOWCAP_REPL_QUIET=1` skips the one-line
workbench greeting, `GLOWCAP_REPL_NO_MOUSE=1` turns mouse handling off, and
`GLOWCAP_REPL_REDUCED_MOTION=1` shortens the flash and motion. Resize, reflow,
and footer tips are covered in-app.

## Agent control plane

```sh
glowcap mcp --tools default
# catalogs: default | full | readonly; discover tools via MCP tools/list
```

This repository wires CapTP MCP into Cursor and Claude through the root
[`glowcap`](../glowcap) shim, which runs `./glowcap mcp --tools default`. Run
`zig build` first; the wiring itself lives in `.cursor/mcp.json` and
`.mcp.json`. Stdio framing is
newline-delimited JSON-RPC. Tool results match argv `--json`, including
`{"ok":false,"error":…}` on failure, and `isError` mirrors the exit code.
MCP state defaults to `.local/glowcap-mcp-state`, relative to the working
directory, so an agent never shares a human argv/REPL identity. Hosting stays
argv-only: `listen` parks on accept, so it is never an MCP tool.

The tool schemas are projected from the CapTP registry, one front-applicable
flag and positional at a time (`--repl` stays argv-only). `call`, `tell`, and
`fetch` expose named fields (`locator`, `name`, `verb`, `args`), and tool calls
that do not match that generated schema are refused as invalid parameters.
After `zig build`, reload the MCP server in the host so the tools pick up the
new binary. For hosts where `glowcap` is
already on `PATH`, a portable stub (no shim; set `GLOWCAP_STATE` explicitly)
lives at [`docs/glowcap-mcp.json`](glowcap-mcp.json).

## Sit in a room

Room presence is `glowcap apps rooms session`. Install
the [Linux/macOS glowcap product](../apps/rooms/host.md), or use the checkout
launcher with `./glowcap apps rooms session`.
Zig owns its command grammar, help, and
completion; the commands use the shared Rust Rooms session application.

```sh
glowcap apps rooms session start --dir "$HOME/.rooms/alice" --nick Alice \
  --locator http://localhost:8080/locator --room garden --room workshop
glowcap apps rooms session listen --dir "$HOME/.rooms/alice"
glowcap apps rooms session reply --dir "$HOME/.rooms/alice" --id 12 --text 'Hello.'
glowcap apps rooms session stop --dir "$HOME/.rooms/alice"
```

The workspace owns its identity and all joined rooms and DMs. Reading does
not acknowledge events; `reply --id` acknowledges after sending, and `dismiss`
acknowledges without speaking. `listen` emits the initial pending batch, then
newly delivered events without repeating earlier ones. It never acknowledges
them; restarting it replays still-pending events. `tick` returns the current
pending batch for one bounded wait.
Managed session commands return JSON; `listen` returns JSONL. `team start`, `team status`,
and `team stop` operate a roster through the same session lifecycle, not a second
implementation. Starting a peer does not start a model consumer.
Rooms has an independent flag scope: `--identity`, `--json`, and `--plain`
belong to the generic CLI and are refused before any Rooms command executes.

Host-initiated browser DMs need a reachable route: browsers can select
**Through the room relay**, while the session needs that relay's URL.
An HTTP(S) bootstrap derives it; `start --relay-url` supplies it explicitly.
The session does not provide WebRTC. See [operating Rooms](../apps/rooms/operating.md)
for local control, limits, and recovery.

## Shell completion and scripting

```sh
eval "$(glowcap completion bash)"   # or zsh | fish
```

A script picks its identity with `GLOWCAP_STATE`, `GLOWCAP_IDENTITY`, or
`--identity`, and should pass `--json` on every verb. `ocapn info` prints the
session summary: the front, the state path, and the partner's `abort_kind` and
`abort` reason when one was retained.

A `keyed-relay` locator names a peer that holds no listening socket (a
browser tab, or any process that registered its identity at a relay instead).
Its `rendezvous-relay` hint carries the dial route; `GLOWCAP_RENDEZVOUS` is
the deployment fallback for a bare locator. It accepts `ws` or `wss`; WSS uses
the platform root store by default. A process that owns a private deployment
can set `GLOWCAP_RELAY_CA_FILE` to a PEM root bundle; the CLI reads it once and
the relay initializer copies the bounded snapshot. The relay carries cleartext CapTP frames and does not
prove who answered. Native peers can seal that path with `noise-relay`. The
browser's managed WebSocket connector can accept the same sealed profile;
`web-peer-test` proves the native CLI can call it through a real Chromium peer
and a local WSS relay
([known limitations](boundaries.md#browser-reachability)):

```sh
export GLOWCAP_RENDEZVOUS=wss://relay.example/relay
glowcap --json ocapn call "ocapn://<key>.keyed-relay" greeter greet world
```

To be that peer rather than dial one, register instead of binding. Registration
and dialing may use different relay endpoints, so provide both. The listener
holds an inbound socket at the registration endpoint and prints a
`keyed-relay` locator carrying the advertised dial route:

```sh
glowcap --json ocapn listen \
  --rendezvous wss://relay.example/register \
  --rendezvous-relay wss://relay.example/relay \
  --publish greeter
```

[ADR-0084](decisions/adr/ADR-0084-glowcap-cli-product-boundary.md) records the
product boundary. [`shipped.md`](shipped.md) lists the commands that exist,
[`boundaries.md`](boundaries.md) records user-facing limits, and the
[`roadmap`](roadmap.md) lists unbuilt product work.
