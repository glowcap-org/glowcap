---
name: serena
description: "Use first for Zig code-symbol work: mapping a file, finding a declaration, callers, or implementations, renaming, replacing or inserting a symbol body, or single-file diagnostics. Also covers cold start, call shapes, memories, and fallback."
---

# Serena MCP: Zig glowcap operator notes

Serena is the first tool for Zig symbols, before text search:

| Task | Tool |
| --- | --- |
| Map a file | `get_symbols_overview` |
| Find a declaration | `find_symbol`, `find_declaration` |
| Find callers | `find_referencing_symbols` |
| Find implementations | `find_implementations` |
| Rename | `rename_symbol` |
| Replace or insert a body | `replace_symbol_body`, `insert_before_symbol` / `insert_after_symbol` |
| Delete a symbol | `safe_delete_symbol` |
| Check one file | `get_diagnostics_for_file` |

Use `depth=1` on a large struct (`Peer`, `Session`) before reading bodies.
Prefer symbol-aware rename and body replacement to search-and-replace.

Use host tools for prose, JSON/YAML, exact literal scans, known byte-pinned
edits, broad inventory, and non-Zig code. Live CapTP belongs to
[glowcap-mcp](../glowcap-mcp/SKILL.md), [glowcap-cli](../glowcap-cli/SKILL.md),
and [rooms-peer](../rooms-peer/SKILL.md).

## Fallback

Check once whether the session has Serena. If it is absent, or a call still
fails after one diagnostic attempt, continue with `rg`, bounded reads, and the
owning checks, and say so once. Repair the MCP only when missing symbol
information blocks a safe edit or the user asks.

## Project State

- Config: [`.serena/project.yml`](../../../.serena/project.yml)
- Cursor MCP: [`.cursor/mcp.json`](../../../.cursor/mcp.json) (stdio, started
  with `serena start-mcp-server`)
- Claude MCP: [`.mcp.json`](../../../.mcp.json) (stdio, through
  `glowcap-dev`, so the pinned server and `zls` run in the worktree's
  devcontainer whether the session runs on the host or inside it)
- Runtime state: `.serena/cache`, `.serena/logs`, and `.serena/memories` are
  per-clone and ignored.

## Cold Start

Warm the language server before deep symbol work. Pick the file closest to your
task focus:

| Task focus                     | Warm with                          |
| ------------------------------ | ---------------------------------- |
| General / unknown              | `src/root.zig`                     |
| Frame / FrameView ownership    | `src/foundation/frame.zig`         |
| Session state / validate-apply | `src/ocapn/session/mod.zig`        |
| Peer API / engine dispatch     | `src/ocapn/engine/mod.zig`         |
| Syrup encode/decode / views    | `src/ocapn/codec/syrup/decode.zig` |
| Model types / clone-free       | `src/ocapn/model/mod.zig`          |
| C ABI surface                  | `src/c_abi/ocapn/mod.zig`          |

The first call after a cold start is slow (about 10 to 15 seconds), so assume cold start before
assuming tool failure.

## Critical: File-Path Constraint

`get_symbols_overview` requires a **file path**, not a directory.
`src/foundation` throws `ValueError` and `src/foundation/frame.zig` works. To
map a directory, list its files and call per file.

## Module Map

Map a module with `get_symbols_overview` on its entry file from the warm-up
table above. [`docs/architecture.md`](../../../docs/architecture.md) owns the
layer tour.

## Common Calls

Map a file:

```json
{
  "name": "get_symbols_overview",
  "arguments": { "relative_path": "src/ocapn/engine/mod.zig" }
}
```

Map children of a struct (e.g. all Peer methods) before reading bodies:

```json
{
  "name": "find_symbol",
  "arguments": {
    "name_path_pattern": "Peer",
    "relative_path": "src/ocapn/engine/mod.zig",
    "depth": 1
  }
}
```

Find a symbol by name pattern across a subtree:

```json
{
  "name": "find_symbol",
  "arguments": { "name_path_pattern": "Frame", "relative_path": "src" }
}
```

Find callers of a specific symbol:

```json
{
  "name": "find_referencing_symbols",
  "arguments": {
    "name_path": "Frame",
    "relative_path": "src/foundation/frame.zig"
  }
}
```

Read a symbol body directly when you already know its name and file:

```json
{
  "name": "find_symbol",
  "arguments": {
    "name_path_pattern": "Peer/send",
    "relative_path": "src/ocapn/engine/mod.zig",
    "include_body": true
  }
}
```

`find_symbol` takes `name_path_pattern`. The reference, rename, and body tools
take `name_path` (exact match).

## Memories

Serena memories are per-clone runtime state under `.serena/memories/`, ignored
by git, so a fresh clone has none. Call `list_memories` before reading one.
The committed rules and docs are the durable guidance.

## Verification

Use `get_diagnostics_for_file` for focused iteration. The
[execution rule](../../rules/cli.md#gates) owns final checks, and Serena use adds
no product-gate run.
