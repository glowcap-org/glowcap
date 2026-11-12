#!/usr/bin/env bash
# glowcap: Format a single agent-edited file (Zig, Rust, TypeScript/TSX/JavaScript, Python).
# Racket has no single-file formatter on PATH; the `bindings-fmt-check` gate
# holds it. The formatters and their per-extension rules live in lib/format.sh,
# which the pre-commit hook shares.
#
# Wired from:
#   .cursor/hooks.json    (afterFileEdit), input is .file_path
#   .claude/settings.json (PostToolUse, Edit|Write|MultiEdit), input is .tool_input.file_path
#
# Failure posture: the edit has already happened, so no exit blocks it. A
# formatter failure, often an unfinished edit, prints its message and exits 2
# for Claude, the code that shows stderr to the model, and 1 for Cursor, whose
# 2 means deny and whose other failures proceed. The owning format check stays
# the gate.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "format-edited-file: jq is not on PATH, so the edited file is not formatted" >&2
  exit 1
fi

payload="$(cat)"
file_path="$(jq -r '.file_path // .tool_input.file_path // empty' <<<"$payload")"
failure=1
[[ "$(jq -r 'has("tool_input")' <<<"$payload")" == true ]] && failure=2

[[ -z "$file_path" ]] && exit 0
[[ ! -f "$file_path" ]] && exit 0

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/format.sh
source "${hook_dir}/lib/format.sh"

# The caller's directory decides where ruff runs, so start from the file's own.
file_dir="$(cd "$(dirname "$file_path")" && pwd -P)"
cd "$file_dir" || exit "$failure"
glowcap_format_files "${file_dir}/$(basename "$file_path")" || exit "$failure"
