#!/usr/bin/env bash
# Point the upstream OCapN test suite at a pancake peer.
#
# Starts the installed `pancake-ocapn-peer` (which serves the canonical
# conformance swiss-nums over `tcp-testing-only`), waits for it to bind, then
# runs the suite against it. This is the external authority pointed back at
# pancake; it reports the real per-test verdict.
#
# Usage:
#   bash conformance/ocapn-conformance/run-against-pancake.sh [all|test-module] [--port=N]
# Default is `all`: every upstream module pancake currently targets, each with a
# 5s cap. Pass one module (e.g. `tests.op_deliver`) to probe one surface.
# --port=N (threaded from `zig build ocapn-conformance -Dport=N`) moves the
# peer off its default 22055 when that port is taken.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

# uv needs writable cache + Python-install dirs; the devcontainer's defaults may
# be read-only, so fall back to temp dirs when the configured dirs cannot be
# written.
if [ -z "${UV_CACHE_DIR:-}" ] || [ ! -w "$UV_CACHE_DIR" ]; then
  export UV_CACHE_DIR="$(mktemp -d)"
fi
if [ -z "${UV_PYTHON_INSTALL_DIR:-}" ] || [ ! -w "$UV_PYTHON_INSTALL_DIR" ]; then
  export UV_PYTHON_INSTALL_DIR="$(mktemp -d)"
fi

PEER=zig-out/bin/pancake-ocapn-peer
PORT=22055
MODULE=all
for arg in "$@"; do
  case "$arg" in
    --port=*) PORT="${arg#--port=}" ;;
    *) MODULE="$arg" ;;
  esac
done
URL="ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=$PORT"
LOG="$(mktemp)"
FILTER='Download|Built|Installed|Building|Audited|Resolved|Prepared|Updating'

if [ ! -x "$PEER" ]; then
  echo "ocapn-conformance: $PEER not built — run 'zig build ocapn-conformance' (it installs the peer before running the suite)" >&2
  exit 1
fi

"$PEER" "--port=$PORT" >"$LOG" 2>&1 &
PEER_PID=$!
trap 'kill "$PEER_PID" 2>/dev/null; rm -f "$LOG"' EXIT

for _ in $(seq 1 100); do
  grep -q PANCAKE-OCAPN-PEER-READY "$LOG" && break
  kill -0 "$PEER_PID" 2>/dev/null || { echo "ocapn-conformance: peer exited early" >&2; cat "$LOG" >&2; exit 1; }
  sleep 0.1
done

echo "ocapn-conformance: running upstream suite module '$MODULE' against the pancake peer"

run_module() {
  module="$1"
  suite_out="$(mktemp)"
  echo "ocapn-conformance: module $module"
  timeout 5 bash conformance/ocapn-conformance/run.sh test "$URL" --test-module "$module" --verbose >"$suite_out" 2>&1
  code=$?
  grep -vE "$FILTER" "$suite_out"
  if [ "$code" -eq 124 ]; then
    echo "ocapn-conformance: $module TIMED OUT after 5s" >&2
  elif ! grep -q "^OK" "$suite_out"; then
    code=1
  fi
  rm -f "$suite_out"
  return "$code"
}

if [ "$MODULE" = "all" ]; then
  for module in \
    tests.op_start_session \
    tests.op_abort \
    tests.op_deliver \
    tests.op_listen \
    tests.op_gc \
    tests.third_party_handoffs
  do
    run_module "$module" || exit $?
  done
  echo "ocapn-conformance: pancake PASSES all targeted upstream OCapN modules"
  exit 0
fi

run_module "$MODULE"
