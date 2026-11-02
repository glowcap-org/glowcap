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
# Failure posture: exit 0 even on formatter error so a half-saved file does not
# block the next edit. `zig build check` is the gate.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

file_path="$(jq -r '.file_path // .tool_input.file_path // empty')"

[[ -z "$file_path" ]] && exit 0
[[ ! -f "$file_path" ]] && exit 0

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/format.sh
source "${hook_dir}/lib/format.sh"

# The caller's directory decides where ruff runs, so start from the file's own.
file_dir="$(cd "$(dirname "$file_path")" && pwd -P)"
cd "$file_dir" || exit 0
glowcap_format_files "${file_dir}/$(basename "$file_path")" || true
exit 0
