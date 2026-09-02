#!/usr/bin/env bash
# Run the pinned upstream suite against glowcap over onion. Glowcap uses the
# operator-supplied Tor endpoints; the suite uses its own pinned OnionNetlayer,
# which owns a separate Tor process and remains the foreign implementation under
# test rather than a glowcap-authored copy of it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

if [ -z "${GLOWCAP_OCAPN_TOR_SOCKS:-}" ]; then
  echo "ocapn-conformance-onion: GLOWCAP_OCAPN_TOR_SOCKS is required (host:port)" >&2
  exit 2
fi
if [ -z "${GLOWCAP_OCAPN_TOR_CONTROL:-}" ]; then
  echo "ocapn-conformance-onion: GLOWCAP_OCAPN_TOR_CONTROL is required (host:port)" >&2
  exit 2
fi
if [ -n "${GLOWCAP_OCAPN_TOR_CONTROL_PASSWORD+x}" ] && [ -n "${GLOWCAP_OCAPN_TOR_CONTROL_COOKIE_FILE+x}" ]; then
  echo "ocapn-conformance-onion: set at most one Tor control credential" >&2
  exit 2
fi

if [ -z "${UV_CACHE_DIR:-}" ] || [ ! -w "$UV_CACHE_DIR" ]; then
  UV_CACHE_DIR="$(mktemp -d)"
  export UV_CACHE_DIR
fi
if [ -z "${UV_PYTHON_INSTALL_DIR:-}" ] || [ ! -w "$UV_PYTHON_INSTALL_DIR" ]; then
  UV_PYTHON_INSTALL_DIR="$(mktemp -d)"
  export UV_PYTHON_INSTALL_DIR
fi

PEER=zig-out/bin/glowcap-ocapn-onion-peer
MODULE=all
MODULE_TIMEOUT="${OCAPN_ONION_MODULE_TIMEOUT:-10m}"
SUITE_TIMEOUT="${OCAPN_ONION_SUITE_TIMEOUT:-20m}"
PROBE_TIMEOUT="${OCAPN_ONION_PROBE_TIMEOUT:-10m}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --peer)
      [ "$#" -ge 2 ] || { echo "ocapn-conformance-onion: --peer needs a path" >&2; exit 2; }
      PEER=$2
      shift 2
      ;;
    *) MODULE=$1; shift ;;
  esac
done

if [ ! -x "$PEER" ]; then
  echo "ocapn-conformance-onion: peer is not executable: $PEER" >&2
  exit 1
fi

LOG="$(mktemp)"
"$PEER" >"$LOG" 2>&1 &
PEER_PID=$!
trap 'kill "$PEER_PID" 2>/dev/null; rm -f "$LOG"' EXIT

URL=
for _ in $(seq 1 300); do
  URL="$(sed -n 's/^GLOWCAP-OCAPN-PEER-READY //p' "$LOG" | tail -n 1)"
  [ -n "$URL" ] && break
  kill -0 "$PEER_PID" 2>/dev/null || {
    echo "ocapn-conformance-onion: peer exited before publishing its service" >&2
    cat "$LOG" >&2
    exit 1
  }
  sleep 0.1
done
if [ -z "$URL" ]; then
  echo "ocapn-conformance-onion: peer did not publish an onion service" >&2
  cat "$LOG" >&2
  exit 1
fi
echo "ocapn-conformance-onion: glowcap peer $URL"

run_suite() {
  python3 tools/run-with-timeout.py --kill-after 5s "$MODULE_TIMEOUT" \
    uv run --project conformance/ocapn-conformance --locked \
    python conformance/ocapn-conformance/onion_test_runner.py "$URL" \
    "$@" --verbose
}

run_module() {
  module="$1"
  suite_out="$(mktemp)"
  echo "ocapn-conformance-onion: module $module"
  run_suite --test-module "$module" >"$suite_out" 2>&1
  code=$?
  cat "$suite_out"
  if [ "$code" -eq 124 ]; then
    echo "ocapn-conformance-onion: $module TIMED OUT after $MODULE_TIMEOUT" >&2
  elif ! grep -q '^OK' "$suite_out"; then
    code=1
  elif grep -q 'skipped=' "$suite_out"; then
    echo "ocapn-conformance-onion: $module reported skipped tests; not counting as a pass" >&2
    code=1
  fi
  rm -f "$suite_out"
  return "$code"
}

run_portable_suite() {
  suite_out="$(mktemp)"
  echo "ocapn-conformance-onion: portable upstream suite"
  python3 tools/run-with-timeout.py --kill-after 5s "$SUITE_TIMEOUT" \
    uv run --project conformance/ocapn-conformance --locked \
    python conformance/ocapn-conformance/onion_test_runner.py "$URL" \
    --exclude-module op_abort --verbose >"$suite_out" 2>&1
  code=$?
  cat "$suite_out"
  if [ "$code" -eq 124 ]; then
    echo "ocapn-conformance-onion: portable suite TIMED OUT after $SUITE_TIMEOUT" >&2
  elif ! grep -q '^OK' "$suite_out"; then
    code=1
  elif grep -q 'skipped=' "$suite_out"; then
    echo "ocapn-conformance-onion: portable suite reported skipped tests; not counting as a pass" >&2
    code=1
  fi
  rm -f "$suite_out"
  return "$code"
}

run_abort_probe() {
  echo "ocapn-conformance-onion: handshake-abort probe"
  python3 tools/run-with-timeout.py --kill-after 5s "$PROBE_TIMEOUT" \
    uv run --project conformance/ocapn-conformance --locked \
    python conformance/ocapn-conformance/handshake_abort_probe.py --locator "$URL"
}

if [ "$MODULE" = all ]; then
  run_abort_probe || exit $?
  test -f conformance/ocapn-conformance/upstream/tests/op_abort.py || {
    echo "ocapn-conformance-onion: upstream tests.op_abort disappeared; re-evaluate the strict probe" >&2
    exit 1
  }
  modules="$(cd conformance/ocapn-conformance/upstream/tests && ls -- *.py | sed 's/\.py$//' | grep -v '^__init__$' | grep -v '^op_abort$' | sort)"
  if [ -z "$modules" ]; then
    echo "ocapn-conformance-onion: no upstream modules found; initialize the pinned submodule" >&2
    exit 1
  fi
  run_portable_suite || exit $?
  echo "ocapn-conformance-onion: glowcap PASSES every portable upstream module plus the strict abort probe over onion"
  exit 0
fi

run_module "$MODULE"
