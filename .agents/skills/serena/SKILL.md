---
name: serena
description: "Use when calling Serena MCP tools for Zig symbols, diagnosing Serena responses, handling cold start, or using Serena memories."
---

# Serena MCP — Zig pancake operator notes

Use this after the [`serena-mcp`](../../rules/serena-mcp.md) rule says Serena is
the right tool.

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
| engine      | `src/ocapn/engine/pipeline.zig` | `decomposeOutboundDeliver`, `borrowedListenerFire`, `classifyListenerDrain`                                                          |
| c_abi       | `src/c_abi/ocapn/mod.zig`       | all `pancake_*` exported C functions                                                                                                   |
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
by git, a fresh clone has none. Call `list_memories` to see what this clone
actually holds before reading one; never assume a named memory exists. The
committed rules and docs, not memories, are the durable guidance.

## Verification

Serena edits are not proof. After code changes, run:

```sh
zig build check
```

Use `get_diagnostics_for_file` only for focused iteration while editing a single
Zig file.
