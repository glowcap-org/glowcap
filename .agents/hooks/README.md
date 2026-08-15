# pancake — Agent Hooks

Canonical home for hook scripts that fire around agent file edits.

| Surface                     | Canonical                                        |
| --------------------------- | ------------------------------------------------ |
| Per-edit formatter dispatch | [`format-edited-file.sh`](format-edited-file.sh) |

[`format-edited-file.sh`](format-edited-file.sh) formats:

- `*.zig` with `zig fmt`
- `*.rs` with `rustfmt` (discovers root `rustfmt.toml`)
- `*.ts` / `*.js` with `deno fmt` (from the file's directory, so the nearest
  `deno.json` applies)

Python and Racket have no single-file formatter on PATH here; `zig build
bindings-fmt-check` holds them. The script exits 0 even when formatting fails;
`zig build check` stays the load-bearing gate. Cursor and Claude point at this
canonical command; `zig build source-check` verifies the tool wiring.
