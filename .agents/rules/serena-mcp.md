---
description: "Serena MCP vs host tools for Zig pancake symbol work."
globs: src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, build.zig
---

# pancake — Serena MCP Discipline

Serena is the first-class code-symbol tool for this Zig repository. Config:
[`.serena/project.yml`](../../.serena/project.yml), [`.cursor/mcp.json`](../../.cursor/mcp.json),
and [`.mcp.json`](../../.mcp.json). The devcontainer installs `serena` on PATH;
Cursor starts the MCP server via stdio (see `.cursor/mcp.json`). Operator notes:
[`serena`](../skills/serena/SKILL.md).

## Use Serena First

Reach for Serena before text search when the task is about Zig code symbols:

| Task | Tool |
| --- | --- |
| Map a file/module | `get_symbols_overview` |
| Find a declaration or definition | `find_symbol`, `find_declaration` |
| Find users/callers of a symbol | `find_referencing_symbols` |
| Find implementations | `find_implementations` |
| Rename a symbol | `rename_symbol` |
| Replace a function/type body | `replace_symbol_body` |
| Insert adjacent code | `insert_before_symbol` / `insert_after_symbol` |
| Safely delete a symbol | `safe_delete_symbol` |
| Check one file while iterating | `get_diagnostics_for_file` |

Use host file tools for prose, JSON/YAML config, exact string/literal scans,
byte-pinned edits where the location is already known, and broad repository
inventory.

## API Constraints

`get_symbols_overview` takes a file path, never a directory — to map a
directory, list its files first and call per-file. `find_symbol` matches a
`name_path_pattern`; every other symbol tool takes an exact `name_path`. The
[serena skill](../skills/serena/SKILL.md) carries the full call shapes.

## Discipline

Warm Serena early by calling `get_symbols_overview` on the file most relevant
to the task. The [serena skill](../skills/serena/SKILL.md) carries the
warm-with table, the module map, cold-start timing, and ready-made calls —
read it before the first call of a session.

Use `depth=1` on a struct to map its children before deciding which bodies to
read with `include_body=true`. Reading an entire large type (e.g. `Peer`,
`Session`) returns hundreds of lines — targeted reads are faster.

Prefer symbol-aware rename/body replacement over search-and-replace for Zig
source. Serena diagnostics are an iteration aid, not the gate. Verify completed
code work with `zig build check`; use focused build steps while iterating.