---
type: static
description: How to call capabilities from a shell, script CapTP with JSON, and run glowcap as an MCP server.
sources:
  - resource: /cli/
  - resource: /docs/glowcap-mcp.json
---

# CapTP CLI

Call a capability from your shell, script CapTP with JSON, or drop glowcap
into an agent via MCP. The binary links the same library as the Zig package.

Flags, CapTP verbs, exit codes, environment, and wait budgets are in the
binary: `glowcap help`, `help ocapn`, and `-h` on any command.

## Install

For the core CLI while developing from the repository root:

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
glowcap help
```

`zig build` installs the core `glowcap` CLI under `zig-out/bin`. The complete
installation adds the Rooms runtimes, prepared browser assets, and skills, and
the checkout launcher installs it:

```sh
./glowcap install --prefix "$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
```

You can also install a complete platform archive, as the
[host guide](../apps/rooms/host.md) describes. Either way, the installer checks
the file inventory, stores the product as a new read-only version, and points
the `bin/glowcap` symlink at it in one atomic step. It refuses to overwrite an
unrelated executable and keeps older versions for processes still running.
An installed binary never builds source or downloads anything.

In the devcontainer, `glowcap` on PATH links to the checkout's `./glowcap`
launcher, which runs the complete product in `zig-out/product`.

- If the product is missing or incomplete, the launcher builds it with
  `rooms-release` (ReleaseSafe, baseline CPU instructions). Linux can build
  through this checkout's devcontainer, and macOS uses its local toolchain.
- Once the product is built, ordinary commands need neither the compiler nor
  the devcontainer.
- After editing source, run `zig build rooms-release` to update the product.
  `./glowcap install` installs it.

To iterate without installing, `zig build glowcap -- <command> …` runs the same
binary through the build graph. The [deployment
guide](../apps/rooms/web/deploy/README.md) covers `./glowcap apps rooms
deployment`, and [build steps](build-steps.md#everyday-steps-and-checks) lists
the Rooms build steps. Run `rooms-release` on its own, not alongside steps that
stage a product with other settings.

## Join a room over iroh

For an encrypted conversation, use the Rooms commands. Rooms sessions use
[iroh](https://www.iroh.computer/) by default. `glowcap apps rooms session`
runs one durable workspace, and `reply --dm PEER` reaches another member
through a directory introduction ([Sit in a room](#sit-in-a-room)).

The generic `ocapn` commands, the REPL, and MCP dial TCP and configured relay
routes, not iroh or WebRTC.

## A local round-trip

This is for local experiments. `ocapn listen` binds loopback `tcp`, the testing
transport: a cleartext `host:port` with no identity proof.

It uses the same demo greeter as the Zig examples, an actor that lives only in
the CLI (`cli/ocapn/builtins.zig`), not in `libglowcap_*`. Its `greet` verb
returns `Hello, <arg>`.

Each terminal gets its own `GLOWCAP_STATE`, so it acts as its own peer, and
`init` creates the identity keys that peer signs its sessions with.

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
glowcap: listening, and will publish greeter when a partner connects (Ctrl-C to stop)
```

The process then waits for a partner. This is not a hang. `%3A` is a
percent-encoded `:`, so the designator is `127.0.0.1:46659`.

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

A different argument gets a different reply:

```sh
glowcap --json ocapn call "$LOC" greeter greet glowcap \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["value"])'
# prints: Hello, glowcap
```

The built-ins are demo actors: `greeter`, with `greet`, `cowsay`,
`glowcapsay`, and `goblinsay`, and `echo`, whose `echo` verb returns its arg.
`Ctrl+C` or `SIGTERM` stops a waiting or serving `listen` cleanly (exit 0).

## Is it up?

`ocapn probe` runs the handshake and nothing else. Start a fresh listen for it,
because a `--publish` peer exits after one partner.

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
| `glowcap repl` | Interactive CapTP lab (full screen on a TTY, line mode otherwise) |
| `glowcap mcp` | MCP server for agents |
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

`glowcap repl` is an interactive CapTP lab on a live session. On a TTY it opens
fullscreen, with the conversation and prompt in the middle and the session's
exports, imports, and answers in a side panel. Without a TTY it stays in line
mode. Type `guide` for a walkthrough.

A locator is optional: start empty and `dial` inside, or dial first. A REPL or
MCP `listen` binds and answers with its locator at once, then accepts partners
on a background thread until `close`. A `--publish` listener started from the
shell serves the one REPL session and exits when you quit:

```sh
# terminal A
export GLOWCAP_STATE=/tmp/glowcap-a
glowcap --json ocapn listen --publish greeter

# terminal B
export GLOWCAP_STATE=/tmp/glowcap-b
glowcap repl                 # sessionless lab, then dial inside
# or: glowcap repl "$LOC"    # dial first (same as ocapn dial --repl)
```

Inside the lab:

```text
help                         # everyday verbs
help captp                   # CapTP noun map (+ light tip: guide)
?                            # short workbench tip (or guide coach while guided)
guide                        # optional CapTP walkthrough (toggle); guide exit leaves
dial ocapn://127.0.0.1%3A….tcp   # no quotes
fetch greeter                # yields a capability id N (see the Imports panel)
call greeter greet world     # deliver by published name
call #N greet world          # same deliver, addressed by capability id
close                        # tear down the session (no library "reset"; close + redial)
tour exports                 # point at a CapTP pane
focus                        # quiet/focus mode (collapse the side panel to counts)
# TTY only: call/fetch/tell/publish settle in the background; a spinner line
# appears in the transcript; the prompt stays usable. CapTP verbs queue FIFO;
# tour/help/focus/guide run immediately. Esc cancels the active wait (#0 is bootstrap).
quit
```

`Tab` completes and `F1` shows the full key map. Mouse, selection, scrolling,
and clipboard behavior are documented in-app. `GLOWCAP_REPL_QUIET=1` skips the
one-line greeting, `GLOWCAP_REPL_NO_MOUSE=1` turns mouse handling off, and
`GLOWCAP_REPL_REDUCED_MOTION=1` shortens the flash and motion.

## Use glowcap from an agent (MCP)

```sh
glowcap mcp --tools default
# catalogs: default | full | readonly; discover tools via MCP tools/list
```

This repository connects CapTP MCP to Cursor and Claude through the root
[`glowcap`](../glowcap) shim, which runs `./glowcap mcp --tools default` and
prepares the product on first use. The configuration lives in
`.cursor/mcp.json` and `.mcp.json`.

- Messages over stdio are newline-delimited JSON-RPC.
- Tool results match the command line's `--json` output, including
  `{"ok":false,"error":…}` on failure, and `isError` follows the exit code.
- MCP state defaults to `.local/glowcap-mcp-state` under the working
  directory, so an agent gets its own identity unless `GLOWCAP_STATE` points
  it somewhere else.
- `listen` is an MCP tool in the `default` and `full` catalogs.
- The tool schemas are generated from the CapTP command registry, one flag or
  argument at a time (`--repl` stays command-line only). `call`, `tell`, and
  `fetch` take named fields (`locator`, `name`, `verb`, `args`), and a tool
  call that does not match the generated schema is refused as invalid.

After rebuilding the product, reload the MCP server in your editor. If
`glowcap` is already on `PATH`, the portable configuration at
[`docs/glowcap-mcp.json`](glowcap-mcp.json) needs no shim. Set `GLOWCAP_STATE`
explicitly there.

## Sit in a room

Room presence is `glowcap apps rooms session`. Install the
[Linux/macOS glowcap product](../apps/rooms/host.md), or use the checkout
launcher with `./glowcap apps rooms session`.

```sh
glowcap apps rooms session start --dir "$HOME/.rooms/alice" --nick Alice \
  --locator http://localhost:8080/locator --room garden --room workshop
glowcap apps rooms session listen --dir "$HOME/.rooms/alice"
glowcap apps rooms session reply --dir "$HOME/.rooms/alice" --id 12 --text 'Hello.'
glowcap apps rooms session stop --dir "$HOME/.rooms/alice"
```

The workspace owns its identity and every room and DM it has joined.

- Reading does not acknowledge events. `reply --id` acknowledges an event after
  sending the reply, and `dismiss` acknowledges it without replying.
- `listen` first prints the pending events, then each new one, never repeating
  any. It never acknowledges them, so restarting it replays the events still
  pending.
- `tick` returns the current pending events, waiting a bounded time for them.
- Session commands print JSON, and `listen` prints JSONL.
- `team start`, `team status`, and `team stop` run a roster of peers through the
  same session lifecycle. Starting a peer does not start a model to read its
  messages.
- Rooms commands take their own flags. `--identity`, `--json`, and `--plain`
  belong to the generic CLI and are refused before any Rooms command runs.

To send a DM to a browser from this session, the session needs the route the
browser chose. A browser that chose **Through the room relay** is dialed
through that relay, whose URL an HTTP or HTTPS bootstrap supplies, or pass
`start --relay-url`. A browser that kept WebRTC is dialed directly when the
session started with `--dial-transports webrtc`, which signals through the
room that introduced the browser and gathers candidates through
`--ice-servers`. [Operating Rooms](../apps/rooms/operating.md) covers local
control, limits, and recovery.

## Shell completion and scripting

```sh
eval "$(glowcap completion bash)"   # or zsh | fish
```

A script picks its identity with `GLOWCAP_STATE`, `GLOWCAP_IDENTITY`, or
`--identity`, and should pass `--json` on every verb. `ocapn info` prints the
session summary: `front` (`argv`, `repl`, or `mcp`), the state path, and the
partner's `abort_kind` and `abort` reason when one was retained.

A `keyed-relay` locator names a peer with no listening socket: a browser tab,
or any process that registered its identity at a relay instead.

- The locator's `rendezvous-relay` hint carries the route to dial.
  `GLOWCAP_RENDEZVOUS` supplies one for a bare locator.
- The route may be `ws` or `wss`. WSS trusts the platform's root certificates
  by default. For a private deployment, set `GLOWCAP_RELAY_CA_FILE` to a PEM
  bundle of roots. The CLI reads it once at startup.
- `keyed-relay` carries cleartext CapTP frames and does not prove who
  answered. Use `noise-relay` to seal the path, which browsers accept too
  ([known limitations](boundaries.md#browser-reachability)).

```sh
export GLOWCAP_RENDEZVOUS=wss://relay.example/relay
glowcap --json ocapn call "ocapn://<key>.keyed-relay" greeter greet world
```

To be that kind of peer, register at a relay instead of binding a socket.
Registration and dialing can use different relay endpoints, so give both. The
listener keeps an inbound connection open at the registration endpoint and
prints a `keyed-relay` locator that carries the dial route:

```sh
glowcap --json ocapn listen \
  --rendezvous wss://relay.example/register \
  --rendezvous-relay wss://relay.example/relay \
  --publish greeter
```

[Known limitations](boundaries.md) records the CLI's limits.
