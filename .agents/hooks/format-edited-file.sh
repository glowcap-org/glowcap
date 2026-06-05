#!/usr/bin/env bash
# pancake — format a single agent-edited Zig file.
#
# Wired from:
#   .cursor/hooks.json    (afterFileEdit)                       — input is .file_path
#   .claude/settings.json (PostToolUse, Edit|Write|MultiEdit)   — input is .tool_input.file_path
#
# Failure posture: exit 0 even on formatter error so a half-saved file does not
# block the next edit. `zig build check` remains the load-bearing gate.

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
      printf 'pancake hook: zig not on PATH; skipping %s\n' "$abs_path" >&2
      exit 0
    fi
    zig fmt "$abs_path" >&2 || true
    ;;
esac
