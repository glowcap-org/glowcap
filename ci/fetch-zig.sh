#!/usr/bin/env bash
# CI checks and releases use this to acquire the pinned Zig dependency graph.
# Fetch packages only, never execute tests. Retry bounded acquisition failures,
# preserving cancellation.
# ZIG_FETCH_RETRY_DELAY controls seconds between attempts (default 5).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
retry_delay=${ZIG_FETCH_RETRY_DELAY:-5}
[[ $retry_delay =~ ^[0-9]+$ ]] || { echo "fetch-zig: retry delay must be whole seconds" >&2; exit 2; }
for attempt in 1 2 3; do
  echo "fetch-zig: dependency acquisition attempt $attempt/3" >&2
  rc=0
  python3 tools/run-with-timeout.py --kill-after 5s --heartbeat 30s 3m zig build --fetch=all || rc=$?
  [[ $rc -eq 0 ]] && exit 0
  case $rc in
    129|130|143) exit "$rc" ;;
  esac
  [[ $attempt -eq 3 ]] && exit "$rc"
  sleep "$retry_delay"
done
