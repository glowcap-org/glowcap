---
name: glowcap-mcp
description: >-
  Use when CapTP must run through the project's glowcap MCP server (Cursor /
  Claude mcp.json): dogfood live CapTP while editing, choose catalogs via
  --tools, fix missing binary/state, or diagnose identity/busy/timeout. Shell
  CapTP → glowcap-cli. Room wake → rooms-peer.
---

# glowcap MCP — CapTP tools in the agent host

**Use glowcap to write glowcap.** When this session needs a live CapTP act while
you edit the library, prefer these MCP tools over a throwaway Zig dialer or
shelling out. Same product binary as argv/REPL
([ADR-0084](../../../docs/decisions/adr/ADR-0084-glowcap-cli-product-boundary.md)).

## When not to use

- Shell listen / REPL / `--json` scripting → [glowcap-cli](../glowcap-cli/SKILL.md)
- Room message wake loop → [rooms-peer](../rooms-peer/SKILL.md)
- Conformance / oracle evidence → Zig gates (MCP success ≠ suite proof)

| Surface | Path |
| --- | --- |
| Cursor | [`.cursor/mcp.json`](../../../.cursor/mcp.json) → `./glowcap mcp --tools default` |
| Claude | [`.mcp.json`](../../../.mcp.json) → `./glowcap mcp --tools default` |
| Shim | [`glowcap`](../../../glowcap) → `zig-out/product/bin/glowcap` |
| Portable stub (PATH `glowcap`) | [`docs/glowcap-mcp.json`](../../../docs/glowcap-mcp.json) |
| Human recipes | [`docs/cli.md`](../../../docs/cli.md) |
| Shell / REPL / listen | [glowcap-cli](../glowcap-cli/SKILL.md) |
| Session lifetimes (all fronts) | [glowcap-cli](../glowcap-cli/SKILL.md) § Session model |

## Dogfood while building glowcap

| Need | How |
| --- | --- |
| Dial / probe / call / tell / fetch / publish across turns | MCP tools (`tools/list` first) |
| Host greeter/echo for a partner | The `listen` tool (`--publish greeter`), or the shell's `ocapn listen` for a foreground accept ([glowcap-cli](../glowcap-cli/SKILL.md)) |
| CapTP lab (rail, imports, cancel) | Shell REPL — glowcap-cli |
| Room presence / wake on messages | [rooms-peer](../rooms-peer/SKILL.md) |
| Oracle / Goblins / suite evidence | Zig gates — MCP success is not conformance |
| Deterministic simulation / timeline | Shell [glowcap-cli](../glowcap-cli/SKILL.md): `glowcap griddle run` is not an MCP tool |
| ocapnviz / A2A | Their own product surfaces, not CapTP MCP tools |

Typical edit-loop: terminal `listen --publish greeter` (one partner then exit),
MCP `call` with the printed locator (do not `probe` first — that consumes the
accept), iterate code, re-listen, MCP again.

## Before the first tool call

1. **Prepare:** `./glowcap version` bootstraps a missing product. After source
   edits, explicitly run `zig build rooms-build` through the work skill's build front.
2. **Reload MCP** in the host if configs or the binary just changed.
3. **Discover tools:** `tools/list` — never invent verb names. Catalog is
   `--tools default|full|readonly` (project configs use `default`).
4. **Identity:** MCP defaults to `GLOWCAP_STATE=.local/glowcap-mcp-state`
   (cwd-relative, under gitignored `.local/`) so it does not share a human
   argv/REPL identity. Override with `GLOWCAP_STATE` / `GLOWCAP_IDENTITY`.
   PATH-only installs (no repo shim) must set `GLOWCAP_STATE` explicitly —
   see the portable stub.

## Session model (MCP-only)

| Fact | Detail |
| --- | --- |
| Lifetime | One long-lived MCP process = one CapTP peer; `dial` and locator `call`/`fetch`/`tell` open it and keep it |
| Results | Tool text is argv `--json` outcome (success *or* `{"ok":false,"error":…}`); `isError` ⇔ nonzero exit; stderr is ops only |
| Teardown | `close` is in the default catalog; process exit / idle caps also end the peer |
| `listen` | Binds and returns the locator at once; accepts on a background thread. One listener per session; `close` stops it (and the held session); `info` reports `listening`/`accepted` |
| `dial --repl` | Hidden from MCP schemas (argv/REPL attach) |
| Locator | Pass `ocapn://…` when no session is open yet (retains). A locator while a session is already held is a one-shot sidecar |
| Stdio | Newline-delimited JSON-RPC (MCP transport); not LSP length headers |

Demo actors on an open session: **greeter** (`greet`, `cowsay`, `glowcapsay`, `goblinsay`) and **echo** (`echo`).
`call` / `tell` / `fetch` prefer named fields (`locator?`, `name`, `verb`,
`args[]` — fetch omits `verb`/`args`). Legacy `args: [locator?] name|#N verb
[arg…]` still works. `dial` / `publish` use `locator` / `name`.

## Typical flow

1. `tools/list` — confirm catalog.
2. `probe` or `dial` with a locator (or call with locator in args).
3. `fetch` / `call` / `tell` / `publish` as needed.
4. `info` for front, identity path, partner abort when retained.
5. `close` when done with the peer (or let the MCP process exit / idle).

## Footguns (MCP-only)

Shared CapTP footguns (`listen` never MCP, `--publish` one-partner,
probe-then-call): [glowcap-cli](../glowcap-cli/SKILL.md) § Session model.

| Mistake | Reality |
| --- | --- |
| MCP server fails to start | Run `./glowcap version`; resolve its build or environment diagnostic |
| Yellow “Loading tools”, then green with none | Stdio is NDJSON (`JSON` + newline); rebuild + reload MCP |
| Blank `isError` tool text | Should be failure JSON; rebuild + reload MCP if empty |
| Share state with a human REPL | Default `.local/glowcap-mcp-state` is separate; do not point both at one dir |
| PATH `glowcap mcp` without state | Set `GLOWCAP_STATE` explicitly (no repo shim) — see portable stub |
| Invent a Zig harness for an in-host CapTP act | Use these tools (or glowcap-cli in a shell) |

## Hand off

| Need | Go to |
| --- | --- |
| Shell argv / CapTP lab REPL / listen | [glowcap-cli](../glowcap-cli/SKILL.md) |
| Room presence wake loop | [rooms-peer](../rooms-peer/SKILL.md) |
| Product boundary | [ADR-0084](../../../docs/decisions/adr/ADR-0084-glowcap-cli-product-boundary.md) |
