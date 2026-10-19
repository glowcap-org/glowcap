---
name: glowcap-cli
description: >-
  Use when CapTP needs to happen live from the shell (locator, call/fetch/tell,
  listen, REPL, --json, dial/handshake failures, identity dirs). In-host MCP →
  glowcap-mcp. Room wake → rooms-peer.
---

# glowcap CLI

`glowcap` is the installable product (`cli/`,
[ADR-0032](../../../docs/decisions/adr/ADR-0032-cli-and-product-boundaries.md))
on the same `driver`/`net` stack as the library. To talk to a peer, host one,
poke a session, or script CapTP, use this binary before opening a new Zig file,
binding stub, or throwaway harness.

| Audience | Authority |
| --- | --- |
| Flags, verbs, exits, env, budgets | `glowcap help` / `help ocapn` / `-h` |
| Human recipes | [`docs/cli.md`](../../../docs/cli.md) |

## When not to use

- CapTP MCP tool calls in-host: [glowcap-mcp](../glowcap-mcp/SKILL.md).
- Room message wake loop: [rooms-peer](../rooms-peer/SKILL.md).
- Multi-persona durable team: [rooms-team](../rooms-team/SKILL.md).
- Protocol and oracle semantics: Zig tests and `oracle-check`.

## Install (once per shell)

In the devcontainer `glowcap` is already on PATH (the image links the
repo-root shim, which lazy-builds). Elsewhere:

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
glowcap help
```

The build graph runs the same binary: `zig build glowcap -- <command> …`. There
is no `glowcap check`. The gates are `zig build check` and `cli-test`.

## Pick a front

| You need… | Front | Shape |
| --- | --- | --- |
| One answered (or fire-and-forget) act | **argv** | `ocapn call\|tell\|fetch\|probe …` |
| CapTP lab (learn / poke a session) | **REPL** | `repl` or `repl <locator>` or `ocapn dial --repl` |
| CapTP tools inside Cursor/Claude (edit-loop dogfood) | **MCP** | [glowcap-mcp](../glowcap-mcp/SKILL.md) (project `mcp.json`) |
| Durable room presence / wake | **rooms-peer** | [rooms-peer](../rooms-peer/SKILL.md) |
| Something else to dial you | **listen** | `ocapn listen …` (background it in argv) |
| Deterministic CapTP simulation / NDJSON timeline | **griddle** | `glowcap griddle run --scenario … --seed …` |

## Session model

| Front | Session lifetime |
| --- | --- |
| argv `call` / `tell` / `fetch` / `probe` | Dial if needed, act, close |
| argv `dial` (no `--repl`) | Opens then **closes**, leaving no session |
| `repl` / `dial --repl` | Process-local open session. The `repl` locator is optional: dial or listen inside, and omit the locator once a session is open |
| argv `listen` | Blocks and accepts until Ctrl-C, or for one partner with `--once` or `--publish` |
| REPL / MCP `listen` | Binds and returns the locator at once, accepts on a background thread, and `close` stops it |
| MCP tools (Cursor/Claude) | One MCP process retains the peer; `close` ends it — [glowcap-mcp](../glowcap-mcp/SKILL.md) |

Rules for a `listen` session:

- `listen --publish` and `--once` accept **one** partner, then exit. Start a
  fresh listen instead of probing and then calling the same process.
- `ocapn locator` and `info` see the last listen URI only inside that process.
  `info` includes the front, the identity path, and the partner
  `abort_kind`/`abort` when retained.
- `Ctrl+C` and `SIGTERM` end a waiting or serving `listen` with exit 0.

CapTP MCP session lifetime and tool schemas live in
[glowcap-mcp](../glowcap-mcp/SKILL.md).

CLI-only demo actors live in `cli/ocapn/builtins.zig` (not in `libglowcap_*`),
which lists their names and verbs. The call shape is
`call <locator> <publish-name|#N> <verb> [arg…]`, and `--json` is preferred.

Example: `listen --publish greeter`, then `call "$LOC" greeter greet world`
returns the value `"Hello, world"`. After `fetch greeter` in the lab,
`call #N greet world` uses the import position shown on the CapTP rail. `#0` is
bootstrap, and a wrong target hangs until cancel or timeout.

On a TTY, `call`, `fetch`, `tell`, and `publish` do not freeze the prompt. A
spinner line waits in the transcript, CapTP verbs queue FIFO, local `tour`,
`help`, and `focus` run immediately, and Esc cancels the active wait.

- **probe** is a handshake only.
- **fetch** bootstrap-fetches a published name (a capability).
- **tell** has the same argv shape as call and gets no answer.

## Identity and ops

- Give each peer one identity: `export GLOWCAP_STATE=/tmp/glowcap-<role>`
  (preferred), or `GLOWCAP_IDENTITY` or `--identity`. Prefer a state dir with
  `…/identity` inside. A loose seed file locks `<path>.lock` beside it, not the
  parent dir.
- `glowcap help` lists CapTP wait budgets and exit codes. Handshake and settle
  are finite, and a hang is exit `6`. Wrap long waits with `timeout N`.
- Run one live CapTP suite at a time, since concurrent listens and `cli-test`
  wedge on ports.

## CapTP lab (REPL)

On a TTY the lab is a CapTP workbench (ECS-lite under `cli/repl/ecs/`, not
Flecs) with a transcript, a prompt dock, and a CapTP rail. Ctrl-O browses, F1
shows the key map, and `focus` quiets the display. `guide` and `guide exit`
start and end an optional walkthrough. Off a TTY the lab is line mode on the
same `exec` path.

Inside, use CapTP verbs, `help` and `help captp`, `tour …`, `?`, and `quit`.
The locator is optional, Tab cycles, and locators paste without quotes.
[`docs/cli.md`](../../../docs/cli.md) owns the key map, mouse handling, and the
`GLOWCAP_REPL_*` switches. Simulations are the separate `glowcap griddle run`
front and do not borrow a live REPL session.

## Footguns

| Mistake | Reality |
| --- | --- |
| Probe then call the same `--publish` listen | Already exited after one partner |
| Expect bare `dial` to keep a session for next argv | Only REPL/MCP retain; argv one-shots. MCP/REPL locator `call`/`fetch`/`tell` retain when none held |
| Same `GLOWCAP_STATE` for both peers | Identity crosstalk / exit `7` |
| `ocapn locator` in the REPL or MCP | Argv-only |
| Quotes around `ocapn://` inside the REPL | `UriParseError` — paste bare |
| Writing Zig to perform a shell-shaped CapTP act | Use this binary |
| Treating shell echo as Goblins/suite evidence | Product adapter only; see community-review matrix |
