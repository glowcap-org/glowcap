#!/usr/bin/env bash
# The CI gate sequence, forge-neutral: the same commands a contributor runs.
# The GitHub mirror (.github/workflows/check.yml) runs this inside the
# committed devcontainer image; Codeberg's hosted runners cannot build that
# image, so .forgejo/workflows/check.yml runs a Zig-only subset directly.
# The project gate itself stays `zig build check`; this script sequences it
# with cross-language sibling gates that need the non-Zig runtimes the image
# carries (the wider sibling list in .agents/rules/cli.md stays excluded
# until its CI minutes are weighed).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# A gate that binds a real loopback port has no per-test deadline: a stale peer
# on a fixed interop port, an orphaned `.zig-cache/o/*/test` process, or a
# silent partner parks the gate in a socket wait forever, and nothing here would
# ever return. Wrap each gate in a generous `timeout` so a true hang fails loud —
# naming the gate and the remediation — instead of wedging the run until a human
# kills it. The ceiling sits far above any healthy gate's wall-clock, so it only
# ever trips on a genuine wedge; override it with GATE_TIMEOUT for a slow runner.
GATE_TIMEOUT="${GATE_TIMEOUT:-20m}"

gate() {
  local rc=0
  timeout --kill-after=30s "$GATE_TIMEOUT" "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
      echo "ci/gates.sh: '$*' exceeded $GATE_TIMEOUT and was killed — likely a wedged socket wait" >&2
      echo "  (a stale peer on a fixed interop port, or an orphaned test process from a dead run)." >&2
      echo "  Sweep for orphans (pkill -f '.zig-cache/o/.*/test'), confirm no concurrent gate is running, and retry." >&2
    fi
    exit "$rc"
  fi
}

gate bash .devcontainer/post-create.sh

gate zig build check
gate zig build bindings-fmt-check
gate zig build bindings
# The browser binding's behavioral proof: two wasm32 Hosts complete a keyed
# handshake driven from JavaScript. The wasm *build* is in `check` (via
# cross-check), but the runtime convergence only runs here (needs deno).
gate zig build wasm-driver-test
# The browser binding's layout descriptor is well formed and agrees with the
# host `abi.ts` mirror on struct shape (needs deno).
gate zig build wasm-abi-layout-check
# The browser binding imports exactly the one behavior-dispatch seam
# env.pancake_behavior_trampoline, nothing else (needs deno).
gate zig build wasm-import-check
gate zig build goblins-interop
gate zig build goblins-handoff
# The gifter direction: pancake mints the signed desc:handoff-give and a live
# Goblins recipient must parse and redeem it. This is the only automated step
# that catches a pancake-side change to the signed give bytes (goblins-handoff
# forwards a Goblins-minted give verbatim, so it cannot).
gate zig build goblins-gift
gate zig build fixture-gen-check
gate zig build ocapn-conformance
gate zig build iroh-interop
# The cross-runtime relay matrix (ADR-0086): one shared harness proves TCP
# forwarding and the non-optional backpressure clause against every runtime's
# relay — the Deno reference relay, the Python relay, and the Rust relay. A
# runtime is a row, never a fork, so no binding can silently lack a proof
# (needs deno + uv + cargo; all three are already on PATH above).
gate zig build bindings-relay
# The matrix's iroh leg: each runtime's relay dials a real iroh endpoint over
# QUIC and carries the browser peer's live session through it. iroh-interop
# above already pays the cargo-iroh build, so the marginal cost is the wasm
# build and the deno-driven runs (needs deno + uv + cargo).
gate zig build bindings-relay-iroh
