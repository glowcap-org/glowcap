#!/usr/bin/env bash
# glowcap: format a single agent-edited file (Zig, Rust, TypeScript/TSX/JavaScript).
# Python and Racket have no single-file formatter on PATH; the
# `bindings-fmt-check` gate holds them.
#
# Wired from:
#   .cursor/hooks.json    (afterFileEdit), input is .file_path
#   .claude/settings.json (PostToolUse, Edit|Write|MultiEdit), input is .tool_input.file_path
#
# Failure posture: exit 0 even on formatter error so a half-saved file does not
# block the next edit. `zig build check` is the gate.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

file_path="$(jq -r '.file_path // .tool_input.file_path // empty')"

[[ -z "$file_path" ]] && exit 0
[[ ! -f "$file_path" ]] && exit 0

abs_path="$(realpath "$file_path")"

case "$abs_path" in
  *.zig)
    if ! command -v zig >/dev/null 2>&1; then
      printf 'glowcap hook: zig not on PATH; skipping %s\n' "$abs_path" >&2
      exit 0
    fi
    zig fmt "$abs_path" >&2 || true
    ;;
  *.rs)
    if ! command -v rustfmt >/dev/null 2>&1; then
      printf 'glowcap hook: rustfmt not on PATH; skipping %s\n' "$abs_path" >&2
      exit 0
    fi
    # Discover the file's config, but never walk its child modules: this hook
    # owns only the edited file. infrastructure-check exercises that boundary.
    rustfmt --config skip_children=true "$abs_path" >&2 || true
    ;;
  *.ts|*.tsx|*.js)
    if ! command -v deno >/dev/null 2>&1; then
      printf 'glowcap hook: deno not on PATH; skipping %s\n' "$abs_path" >&2
      exit 0
    fi
    # Run from the file's directory so deno discovers the nearest deno.json
    # (the bindings workspace and the root scope carry different fmt blocks).
    (cd "$(dirname "$abs_path")" && deno fmt "$abs_path") >&2 || true
    ;;
esac
