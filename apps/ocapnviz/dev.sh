#!/usr/bin/env bash
# Dev-server wrapper that supervises vite so shutdown is reliable.
#
# Two things break shutdown when vite runs bare in a terminal:
#
# 1. Vite's "press h + enter to show help" puts stdin in raw mode, so the
#    kernel stops translating Ctrl-C into SIGINT and vite has to handle the
#    keystroke itself — which it doesn't always do cleanly through deno's
#    npm-compat layer.
# 2. Closing the terminal pane (or restarting the IDE) does not kill vite by
#    default. If nothing is supervising deno, the kernel reparents it to init
#    and it runs forever — holding port 5173 hostage so the next `bash dev.sh`
#    lands on 5174, then 5175, and so on.
#
# This script runs deno as a child with stdin from /dev/null and traps
# INT/TERM/HUP/EXIT so it always SIGTERMs the child before it exits. You lose
# vite's in-terminal `h` / `q` / `r` shortcuts, but HMR still works through
# the browser, Ctrl-C kills the dev server cleanly, and closing the terminal
# does too.
#
# If a `deno run -A npm:vite` ever shows `PPID 1` in `ps`, that's a pre-fix
# orphan — `kill -9 <pid>` and start fresh.
set -euo pipefail
cd "$(dirname "$0")"

command -v deno >/dev/null 2>&1 || {
  echo "dev.sh: deno not on PATH" >&2
  exit 1
}

child=""
cleanup() {
  if [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
}
trap cleanup INT TERM HUP EXIT

deno run -A npm:vite </dev/null &
child=$!
wait "$child"
