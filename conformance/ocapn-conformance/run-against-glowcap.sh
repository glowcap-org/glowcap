#!/usr/bin/env bash
# Point the upstream OCapN test suite at a glowcap peer.
#
# Starts the build-provided `glowcap-ocapn-peer` (which serves the canonical
# conformance swiss-nums over `tcp-testing-only`), waits for it to bind, then
# runs the suite against it. This is the external authority pointed back at
# glowcap; it reports the real per-test verdict.
#
# Usage:
#   bash conformance/ocapn-conformance/run-against-glowcap.sh [all|test-module] [--port=N] [--peer PATH]
#   Add --profile=next --adoption-tool PATH for the manifest-selected next lane.
# Default is `all`: every module in the upstream tree except the non-portable
# `tests.op_abort` case replaced by the stricter local probe below. The list is
# derived recursively from upstream/tests/, so a submodule bump cannot silently shrink
# coverage. Each module has a 5s cap (raise with OCAPN_MODULE_TIMEOUT), and the
# abort probe has a 10s cap (OCAPN_PROBE_TIMEOUT). Pass one module (e.g.
# `tests.op_deliver`) to run the raw upstream surface.
# --port=N (threaded from `zig build ocapn-conformance -Dport=N`) moves the
# peer off its default 22055 when that port is taken.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

SCRATCH="$(mktemp -d)" || exit 1
PEER_PID=
peer_is_running() {
  jobs -pr | grep -Fxq "$PEER_PID"
}
cleanup() {
  if [ -n "$PEER_PID" ]; then
    kill "$PEER_PID" 2>/dev/null || true
    for _ in $(seq 1 40); do
      peer_is_running || break
      sleep 0.05
    done
    if peer_is_running; then
      echo "ocapn-conformance: peer did not stop after 2s; killing it" >&2
      kill -KILL "$PEER_PID" 2>/dev/null || true
    fi
    wait "$PEER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$SCRATCH"
}
trap cleanup EXIT

# uv needs writable cache + Python-install dirs; the devcontainer's defaults may
# be read-only, so fall back to temp dirs when the configured dirs cannot be
# written.
if [ -z "${UV_CACHE_DIR:-}" ] || [ ! -w "$UV_CACHE_DIR" ]; then
  UV_CACHE_DIR="$SCRATCH/uv-cache"
  mkdir -p "$UV_CACHE_DIR" || exit 1
  export UV_CACHE_DIR
fi
if [ -z "${UV_PYTHON_INSTALL_DIR:-}" ] || [ ! -w "$UV_PYTHON_INSTALL_DIR" ]; then
  UV_PYTHON_INSTALL_DIR="$SCRATCH/uv-python"
  mkdir -p "$UV_PYTHON_INSTALL_DIR" || exit 1
  export UV_PYTHON_INSTALL_DIR
fi

PEER=zig-out/bin/glowcap-ocapn-peer
PORT=22055
MODULE=all
PROFILE=baseline
ADOPTION_TOOL=
# Per-module and probe caps, raisable on a slow runner the way ci/gates.sh
# takes GATE_TIMEOUT. A cap that fires is reported as a timeout and fails the
# run, so the only thing a too-tight cap buys is a scheduling hiccup wearing
# the costume of a protocol failure in a public log. Crossed-hellos cases in
# op_start_session can use most of a module's budget.
MODULE_TIMEOUT="${OCAPN_MODULE_TIMEOUT:-5s}"
PROBE_TIMEOUT="${OCAPN_PROBE_TIMEOUT:-10s}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile=next) PROFILE=next; shift ;;
    --adoption-tool)
      [ "$#" -ge 2 ] || { echo "ocapn-conformance: --adoption-tool needs a path" >&2; exit 2; }
      ADOPTION_TOOL=$2; shift 2 ;;
    --port=*) PORT="${1#--port=}"; shift ;;
    --peer)
      [ "$#" -ge 2 ] || { echo "ocapn-conformance: --peer needs a path" >&2; exit 2; }
      PEER=$2
      shift 2
      ;;
    *) MODULE=$1; shift ;;
  esac
done
export GLOWCAP_OCAPN_CONFORMANCE_PORT="$PORT"
URL="ocapn://JadQ0++RzsD4M+40uLxTWVaVqM10DcBJ.tcp-testing-only?host=127.0.0.1&port=$PORT"
LOG="$SCRATCH/peer.log"
FILTER='Download|Built|Installed|Building|Audited|Resolved|Prepared|Updating'

if [ ! -x "$PEER" ]; then
  echo "ocapn-conformance: peer is not executable: $PEER" >&2
  echo "ocapn-conformance: run 'zig build ocapn-conformance' once (it installs the peer), or pass --peer PATH" >&2
  exit 1
fi

peer_args=("--port=$PORT")
if [ "$PROFILE" = next ]; then
  [ -x "$ADOPTION_TOOL" ] || { echo "next conformance requires --adoption-tool PATH" >&2; exit 2; }
  peer_args+=(--profile=next)
fi
"$PEER" "${peer_args[@]}" >"$LOG" 2>&1 &
PEER_PID=$!

peer_ready=false
for _ in $(seq 1 100); do
  if grep -q GLOWCAP-OCAPN-PEER-READY "$LOG"; then
    peer_ready=true
    break
  fi
  kill -0 "$PEER_PID" 2>/dev/null || { echo "ocapn-conformance: peer exited early" >&2; cat "$LOG" >&2; exit 1; }
  sleep 0.1
done
if [ "$peer_ready" != true ]; then
  echo "ocapn-conformance: peer did not become ready after 10s" >&2
  cat "$LOG" >&2
  exit 1
fi

run_handshake_abort_probe() {
  echo "ocapn-conformance: handshake-abort probe (pre-setup abort + invalid signature + invalid version)"
  # Same committed environment as run.sh: the probe imports the suite's own
  # message types, which need cryptography on the uv-provided interpreter.
  python3 tools/run-with-timeout.py --kill-after 5s "$PROBE_TIMEOUT" uv run \
    --project conformance/ocapn-conformance --locked \
    python conformance/ocapn-conformance/handshake_abort_probe.py --port="$PORT"
  probe_code=$?
  if [ "$probe_code" -eq 124 ]; then
    echo "ocapn-conformance: handshake-abort probe TIMED OUT after $PROBE_TIMEOUT" >&2
  fi
  return "$probe_code"
}

run_module() {
  module="$1"
  suite_out="$SCRATCH/suite.out"
  echo "ocapn-conformance: module $module"
  if [ "$PROFILE" = next ]; then
    python3 tools/run-with-timeout.py --kill-after 5s "$MODULE_TIMEOUT" uv run --project conformance/ocapn-conformance --locked python conformance/ocapn-conformance/next_runner.py "$URL" --module "$module" --adoption-tool "$ADOPTION_TOOL" >"$suite_out" 2>&1
  else
  python3 tools/run-with-timeout.py --kill-after 5s "$MODULE_TIMEOUT" bash conformance/ocapn-conformance/run.sh test "$URL" --test-module "$module" --verbose >"$suite_out" 2>&1
  fi
  code=$?
  grep -vE "$FILTER" "$suite_out"
  if ! kill -0 "$PEER_PID" 2>/dev/null; then
    echo "ocapn-conformance: glowcap peer exited during $module" >&2
    cat "$LOG" >&2
    return 1
  fi
  if [ "$PROFILE" = next ] && [ "$code" -eq 77 ]; then
    grep -q '^DEFERRED ' "$suite_out" || return 1
    return 0
  fi
  if [ "$code" -eq 124 ]; then
    echo "ocapn-conformance: $module TIMED OUT after $MODULE_TIMEOUT" >&2
    cat "$LOG" >&2
  elif ! grep -q "^OK" "$suite_out"; then
    code=1
  elif grep -q "skipped=" "$suite_out"; then
    # unittest prints `OK (skipped=n)` for a green run with skips; a skipped
    # upstream case is not a glowcap pass, so refuse it rather than report one.
    echo "ocapn-conformance: $module reported skipped tests; not counting as a pass" >&2
    code=1
  fi
  return "$code"
}

if [ "$MODULE" = "all" ]; then
  run_handshake_abort_probe || exit $?
  # Derive the module list from the upstream tree itself, so a submodule bump
  # that adds a module fails loud here (untargeted = failure) instead of
  # silently shrinking what "all targeted modules" means.
  # `tests.op_abort` rejects Linux's ConnectionResetError even though that is
  # the observable result of the required teardown when its own extra hello is
  # unread. The probe above checks that case more strictly: timeout is not a
  # pass. Keep the raw upstream module available as an explicit diagnostic,
  # while the aggregate substitutes the portable protocol check.
  test -f conformance/ocapn-conformance/upstream/tests/op_abort.py || {
    echo "ocapn-conformance: upstream tests.op_abort disappeared; re-evaluate the local probe" >&2
    exit 1
  }
  modules="$(cd conformance/ocapn-conformance/upstream && find tests -type f -name '*.py' ! -name '__init__.py' | sed 's/\.py$//; s|/|.|g' | sort)"
  if [ "$PROFILE" = baseline ]; then
    modules="$(printf '%s\n' "$modules" | grep -v '^tests.op_abort$')"
  fi
  if [ -z "$modules" ]; then
    echo "ocapn-conformance: no upstream test modules under conformance/ocapn-conformance/upstream/tests" >&2
    echo "ocapn-conformance: run 'bash conformance/bootstrap-submodules.sh' to initialize the pinned submodules" >&2
    exit 1
  fi
  for module in $modules; do
    run_module "$module" || exit $?
  done
  if [ "$PROFILE" = next ]; then
    run_module next_cases || exit $?
    echo "ocapn-conformance-next: adopted upstream and draft cases PASS; deferred modules are reported separately"
  else
    echo "ocapn-conformance: glowcap PASSES every portable upstream module plus the strict abort probe"
  fi
  exit 0
fi

run_module "$MODULE"
