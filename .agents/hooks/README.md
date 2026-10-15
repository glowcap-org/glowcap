# glowcap — Agent Hooks

[`format-edited-file.sh`](format-edited-file.sh) formats the file named by a
Cursor `afterFileEdit` or Claude `PostToolUse` event:

- `*.zig` with `zig fmt`.
- `*.rs` with `rustfmt`, using the file's config and skipping child modules.
- `*.ts`, `*.tsx`, and `*.js` with `deno fmt` from the file's directory, so the
  nearest `deno.json` applies.

An unfinished edit may fail to format. The hook reports formatter errors and
exits zero so the next edit can proceed, so the owning format check is still
required. `bindings-fmt-check` owns Python and Racket formatting.

`zig build source-check` verifies the tool wiring. `zig build
infrastructure-check` exercises both event payloads, non-root invocation, Rust
file isolation, Deno config discovery, and formatter failure behavior.

Design review belongs to the [work skill](../skills/work/SKILL.md#review-the-diff-cold).
Hooks perform bounded operations and print no advisory review prose.
