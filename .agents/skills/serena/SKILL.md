---
name: serena
description: "Use first for Zig code-symbol work: mapping a file, finding a declaration, callers, or implementations, renaming, replacing or inserting a symbol body, or single-file diagnostics. Also covers cold start, call shapes, memories, and fallback."
---

# Serena MCP — Zig glowcap operator notes

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
Prefer symbol-aware rename and body replacement over search-and-replace.

Use host tools instead for prose, JSON/YAML, exact literal scans, known
byte-pinned edits, broad inventory, and non-Zig code. Live CapTP belongs to
[glowcap-mcp](../glowcap-mcp/SKILL.md), [glowcap-cli](../glowcap-cli/SKILL.md),
and [rooms-peer](../rooms-peer/SKILL.md).

## Fallback

Check once whether the session has Serena. If it is absent, or a call still
fails after one diagnostic attempt, continue with `rg`, bounded reads, and the
owning checks, and say so once. Repair the MCP only when missing symbol
information blocks a safe edit or the user asked for it.

## Project State

- Config: [`.serena/project.yml`](../../../.serena/project.yml)
- Cursor MCP: [`.cursor/mcp.json`](../../../.cursor/mcp.json) (stdio; Cursor
  starts `serena start-mcp-server`)
- Claude MCP: [`.mcp.json`](../../../.mcp.json) (stdio; starts its own server)
- Runtime state: `.serena/cache`, `.serena/logs`, `.serena/memories` are
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

The first call after a cold start is slow (~10–15 s); assume cold start before
assuming tool failure.

## Critical: File-Path Constraint

`get_symbols_overview` requires a **file path**, not a directory.
`src/foundation` throws `ValueError`; `src/foundation/frame.zig` works. When you
need to map a directory, list files first then call per-file.

## Module Map

| Module      | Key file                        | Key symbols                                                                                                                            |
| ----------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| foundation  | `src/foundation/frame.zig`      | `Frame`, `FrameView`, `FrameShape`                                                                                                     |
| foundation  | `src/foundation/crypto.zig`     | `PeerKey`, `Signature`, `SecretKey`                                                                                                    |
| foundation  | `src/foundation/id.zig`         | `PeerId`, `SessionId`                                                                                                                  |
| model       | `src/ocapn/model/mod.zig`       | `Message`, `Reference`, `Argument`, `Resolution`, `Deliver`, `Resolve`, `StartSession`, `HandoffGive`, `HandoffReceive`, `AbortReason` |
| codec       | `src/ocapn/codec/syrup/mod.zig` | `encodeMessage`, `decodeBody`, `decodePrefix`, `decodeOwned`                                                                           |
| session     | `src/ocapn/session/mod.zig`     | `Session` (validate/apply, all tables)                                                                                                 |
| engine      | `src/ocapn/engine/mod.zig`      | `Peer`, `StepOutcome`, `Event`, `EventKind`                                                                                            |
| engine      | `src/ocapn/engine/pipeline.zig` | `borrowedListenerFire`, `classifyListenerDrain`, `drainAnswerConsequencesTarget`                                                      |
| c_abi       | `src/c_abi/ocapn/mod.zig`       | all `glowcap_*` exported C functions                                                                                                   |
| oracle      | `src/oracle/mod.zig`            | scenario trace runners                                                                                                                 |

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

`find_symbol` uses `name_path_pattern`; all reference/rename/body tools use
`name_path` (exact match).

## Memories

Serena memories are per-clone runtime state under `.serena/memories/`, ignored
by git, so a fresh clone has none. Call `list_memories` before reading one and
never assume a named memory exists. The committed rules and docs are the
durable guidance.

## Verification

Use `get_diagnostics_for_file` for focused iteration. The
[execution rule](../../rules/cli.md#gates) owns final checks; Serena use adds
no product-gate run.
