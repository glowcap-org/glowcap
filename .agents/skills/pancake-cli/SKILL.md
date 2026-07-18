---
name: pancake-cli
description: >-
  Use when CapTP needs to happen live from the shell (locator, call/fetch/tell,
  listen, REPL, --json, dial/handshake failures, identity dirs). In-host MCP →
  pancake-mcp. Room wake → rooms-peer.
---

# pancake CLI

**This is CapTP in your hands.** `pancake` is the installable product (`cli/`,
[ADR-0084](../../../docs/decisions/adr/ADR-0084-pancake-cli-product-boundary.md)) —
same `driver`/`net` stack as the library. When the job is to *talk to a peer*,
*host one*, *poke a session*, or *script CapTP*, do it here. Do not open a new
Zig file, binding stub, or throwaway harness first.

| Audience | Authority |
| --- | --- |
| Flags, verbs, exits, env, budgets | `pancake help` / `help ocapn` / `-h` |
| Human recipes | [`docs/cli.md`](../../../docs/cli.md) |
| CapTP via agent-host MCP | [pancake-mcp](../pancake-mcp/SKILL.md) |
| Room wake loop | [rooms-peer](../rooms-peer/SKILL.md) |

## When not to use

- CapTP MCP tool calls in-host → [pancake-mcp](../pancake-mcp/SKILL.md)
- Room message wake loop → [rooms-peer](../rooms-peer/SKILL.md)
- Multi-persona durable team → [rooms-team](../rooms-team/SKILL.md)
- Protocol / oracle semantics → Zig tests, `oracle-check`

## Install (once per shell)

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
pancake help
```

Same binary via the build graph: `zig build pancake -- <command> …`. No
`pancake check` — gates are `zig build check` / `cli-test`.

## Pick a front

| You need… | Front | Shape |
| --- | --- | --- |
| One answered (or fire-and-forget) act | **argv** | `ocapn call\|tell\|fetch\|probe …` |
| CapTP lab (learn / poke a session) | **REPL** | `repl` or `repl <locator>` or `ocapn dial --repl` |
| CapTP tools inside Cursor/Claude (edit-loop dogfood) | **MCP** | [pancake-mcp](../pancake-mcp/SKILL.md) (project `mcp.json`) |
| Durable room presence / wake | **rooms-peer** | [rooms-peer](../rooms-peer/SKILL.md) |
| Something else to dial *you* | **argv listen** | background `ocapn listen …` |
| Sim / timeline (not built) | **griddle** | `griddle status` placeholder only |

## Session model (load-bearing)

| Front | Session lifetime |
| --- | --- |
| argv `call` / `tell` / `fetch` / `probe` | Dial if needed, act, close |
| argv `dial` (no `--repl`) | Opens then **closes** — no leftover session |
| `repl` / `dial --repl` | Process-local open session; `repl` locator optional (dial inside; listen argv-only); omit locator later once open |
| `listen` | Argv-only; blocks. **Never** an MCP tool |
| MCP tools (Cursor/Claude) | One MCP process retains the peer; `close` ends it — [pancake-mcp](../pancake-mcp/SKILL.md) |

`listen --publish` / `--once` accept **one** partner then exit. Do not probe
then call the same process — start a fresh listen. `ocapn locator` / `info`
see the last listen URI only inside that process. `info` includes front,
identity path, and partner `abort_kind`/`abort` when retained. CapTP MCP
session lifetime and tool schemas: [pancake-mcp](../pancake-mcp/SKILL.md).

CLI-only demo actors (`cli/ocapn`, not `libpancake_*`): **greeter** (verbs
`greet` → `Hello, <arg>`, `cowsay` / `pancakesay` / `goblinsay` → ASCII
balloons) and **echo** (verb `echo`, returns its arg).
Shape: `call <locator> <publish-name|#N> <verb> [arg…]`. Prefer `--json`.
`Ctrl+C` / `SIGTERM` ends a waiting or serving `listen` (exit 0).

Example: `listen --publish greeter` then
`call "$LOC" greeter greet world` becomes value `"Hello, world"` (arg was `world`).
After `fetch greeter` in the lab, `call #N greet world` uses the import
position shown on the CapTP rail. On a TTY, `call`/`fetch`/`tell`/`publish`
do not freeze the prompt: a spinner line waits in the transcript, CapTP verbs
queue FIFO, local `tour`/`help`/`focus` run immediately, and Esc cancels the
active wait (`#0` is bootstrap — wrong target hangs until cancel/timeout).

- **probe** — handshake only.
- **fetch** — bootstrap-fetch a published name (capability), not handshake-only.
- **tell** — same argv shape as call, no answer.

## Identity and ops

- One identity per peer: `export PANCAKE_STATE=/tmp/pancake-<role>` (preferred),
  or `PANCAKE_IDENTITY` / `--identity`. Prefer a state dir with `…/identity`
  inside; a loose seed file locks `<path>.lock` beside it (not the parent dir).
- CapTP wait budgets and exit codes: `pancake help` (finite handshake/settle;
  hang ≈ exit `6`). Wrap long waits with `timeout N`. One live CapTP suite at
  a time — concurrent listens / `cli-test` wedge on ports.

## CapTP lab (REPL)

TTY: CapTP workbench (ECS-lite under `cli/repl/ecs/` — not Flecs): transcript
+ prompt dock, CapTP rail, modes (Ctrl-O browse, F1 help, `focus` quiet), ↑↓
history, expandable blocks, mouse (wheel/click; character drag-select + OSC 52;
Shift-drag = terminal select), idle CapTP pump, log divert, resize reflow.
Optional walkthrough via `guide` / `guide exit` (stage strip + coach tips);
default is workbench. Non-TTY: line mode, same `exec` path. Locator optional.
Inside: CapTP verbs, `help` / `help captp`, `tour …`, `?`, `quit`. Tab cycle;
paste locators without quotes. `PANCAKE_REPL_QUIET=1` /
`PANCAKE_REPL_NO_MOUSE=1` / `PANCAKE_REPL_REDUCED_MOTION=1`. Walkthrough:
[`docs/cli.md`](../../../docs/cli.md). Sim brand: `pancake griddle` stub.

## Footguns

| Mistake | Reality |
| --- | --- |
| Probe then call the same `--publish` listen | Already exited after one partner |
| Expect bare `dial` to keep a session for next argv | Only REPL/MCP retain; argv one-shots. MCP/REPL locator `call`/`fetch`/`tell` retain when none held |
| Same `PANCAKE_STATE` for both peers | Identity crosstalk / exit `7` |
| CapTP MCP tools without pancake-mcp skill | Load [pancake-mcp](../pancake-mcp/SKILL.md) |
| `listen` via MCP | Argv-only by design |
| Quotes around `ocapn://` inside the REPL | `UriParseError` — paste bare |
| Writing Zig to perform a shell-shaped CapTP act | Use this binary |
| Treating shell echo as Goblins/suite evidence | Product adapter only — see community-review matrix |

## Hand off

| Need | Go to |
| --- | --- |
| Room wake loop | [rooms-peer](../rooms-peer/SKILL.md) |
| Human walkthrough | [`docs/cli.md`](../../../docs/cli.md) |
| Product boundary | [ADR-0084](../../../docs/decisions/adr/ADR-0084-pancake-cli-product-boundary.md) |
| Project MCP (Cursor/Claude) | [pancake-mcp](../pancake-mcp/SKILL.md) |
| Portable MCP stub (`pancake` on PATH) | [`docs/examples/pancake-mcp.json`](../../../docs/examples/pancake-mcp.json) |
