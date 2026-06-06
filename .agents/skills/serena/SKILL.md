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
- Runtime state: `.serena/cache`, `.serena/logs`, `.serena/memories`
  are per-clone and ignored.

## Cold Start

Warm the language server before deep symbol work. Pick the file closest to your
task focus:

| Task focus | Warm with |
| --- | --- |
| General / unknown | `src/root.zig` |
| Frame / FrameView ownership | `src/foundation/frame.zig` |
| Session state / validate-apply | `src/session/mod.zig` |
| Peer API / engine dispatch | `src/engine/mod.zig` |
| Syrup encode/decode / views | `src/codec/syrup/core.zig` |
| Model types / clone-free | `src/model/mod.zig` |
| C ABI surface | `src/c_abi/mod.zig` |

The first call after a cold start is slow (~10–15 s); assume cold start before
assuming tool failure.

## Critical: File-Path Constraint

`get_symbols_overview` requires a **file path**, not a directory.
`src/foundation` throws `ValueError`; `src/foundation/frame.zig` works.
When you need to map a directory, list files first then call per-file.

## Module Map

| Module | Key file | Key symbols |
| --- | --- | --- |
| foundation | `src/foundation/frame.zig` | `Frame`, `FrameView`, `FrameShape` |
| foundation | `src/foundation/crypto.zig` | `PeerKey`, `Signature`, `SecretKey` |
| foundation | `src/foundation/id.zig` | `PeerId`, `SessionId` |
| model | `src/model/mod.zig` | `Message`, `Reference`, `Argument`, `Resolution`, `Deliver`, `Resolve`, `StartSession`, `HandoffGive`, `HandoffReceive`, `AbortReason` |
| codec | `src/codec/syrup/core.zig` | `MessageView`, `DeliverView`, `encodeMessage`, `decodeView`, `ownedFromView` |
| session | `src/session/mod.zig` | `Session` (validate/apply, all tables) |
| engine | `src/engine/mod.zig` | `Peer`, `StepOutcome`, `Event`, `EventKind` |
| engine | `src/engine/pipeline.zig` | `decomposeOutboundDeliver`, `synthesizeListenerFire`, `classifyListenerDrain` |
| c_abi | `src/c_abi/mod.zig` | all `pancake_*` exported C functions |
| conformance | `src/conformance/mod.zig` | scenario trace runners |

## Common Calls

Map a file:
```json
{"name": "get_symbols_overview", "arguments": {"relative_path": "src/engine/mod.zig"}}
```

Map children of a struct (e.g. all Peer methods) before reading bodies:
```json
{"name": "find_symbol", "arguments": {"name_path_pattern": "Peer", "relative_path": "src/engine/mod.zig", "depth": 1}}
```

Find a symbol by name pattern across a subtree:
```json
{"name": "find_symbol", "arguments": {"name_path_pattern": "Frame", "relative_path": "src"}}
```

Find callers of a specific symbol:
```json
{"name": "find_referencing_symbols", "arguments": {"name_path": "Frame", "relative_path": "src/foundation/frame.zig"}}
```

Read a symbol body directly when you already know its name and file:
```json
{"name": "find_symbol", "arguments": {"name_path_pattern": "Peer/send", "relative_path": "src/engine/mod.zig", "include_body": true}}
```

`find_symbol` uses `name_path_pattern`; all reference/rename/body tools use
`name_path` (exact match).

## Memories

Read `mem:core` for the architecture overview and pointers to sub-memories.
Read `mem:architecture/session` for validate/apply, table ownership, and state machine.
Read `mem:tooling/serena` for tool constraints and warm-up strategy.

## Verification

Serena edits are not proof. After code changes, run:

```sh
zig build check
```

Use `get_diagnostics_for_file` only for focused iteration while editing a single
Zig file.
