# glowcap — Agent Hooks

Two hooks format code, and both call one library,
[`lib/format.sh`](lib/format.sh), so a file formats the same way whoever
touches it:

- `*.zig` with `zig fmt`.
- `*.rs` with `rustfmt`, using the file's config and skipping child modules.
- `*.ts`, `*.tsx`, `*.js`, and `*.mjs` with `deno fmt`, run once per Deno scope
  from the nearest directory holding a `deno.json`, so that scope's `fmt` block
  applies.
- `*.py` with `ruff format`, under the root `ruff.toml`. A file `ruff.toml`
  excludes stays as it is.

`bindings-fmt-check` owns Racket formatting. A file that a scope's `fmt` block
excludes, such as a generated file, is left alone.

## After an agent edit

[`format-edited-file.sh`](format-edited-file.sh) formats the file named by a
Cursor `afterFileEdit` or Claude `PostToolUse` event. An unfinished edit may
fail to format. The hook reports formatter errors and exits zero so the next
edit can proceed, so the owning format check remains the gate.

## Before a commit

[`pre-commit`](pre-commit) formats the staged files of those extensions and
stages the result, so a commit never carries unformatted code. Git runs it once
`core.hooksPath` is `.agents/hooks`. The devcontainer sets that on first open
(`.devcontainer/hooks/post-create.sh`), and a plain clone runs
`git config core.hooksPath .agents/hooks` once.

The hook refuses the commit in two cases:

- A staged file also has unstaged changes. Formatting the working copy would
  fold those edits into the commit, so the hook names the files. Stage the
  whole file or stash the rest with `git stash push --keep-index`.
- A formatter rejects a staged file, for example on a syntax error. The
  formatter's own message is printed above the refusal.

When a formatter is not on `PATH`, the hook runs the same library through the
devcontainer front, `.devcontainer/bin/run.sh`. If the front fails because no
container is running, the hook refuses and names the escape: `git commit
--no-verify` skips the hook for that commit, and the format checks still gate
the change.

## Checks

`zig build source-check` verifies the editor-hook wiring. `zig build
infrastructure-check` exercises both event payloads, non-root invocation, Rust file isolation, Deno config discovery, and
formatter failure behavior for the edit hook. It also commits in temporary
repositories to cover the pre-commit hook, which Git skips when it is not executable: formatted blobs, one Deno scope per
config, partial staging, a syntax error, a Markdown-only commit, and the
missing-formatter path through a stub front.

Design review belongs to the [work skill](../skills/work/SKILL.md#review-the-diff-cold).
Hooks perform bounded operations and print no advisory review prose.
