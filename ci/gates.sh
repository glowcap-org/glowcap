#!/usr/bin/env bash
# The CI gate sequence, forge-neutral: the same commands a contributor runs.
# The GitHub mirror (.github/workflows/check.yml) runs this inside the
# committed devcontainer image. The Codeberg origin has no project workflow.
# The project gate itself stays `zig build check`; this script sequences it
# with cross-language sibling gates that need the non-Zig runtimes the image
# carries (the wider sibling list in .agents/rules/cli.md stays excluded
# until its CI minutes are weighed).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# A gate that binds a real loopback port has no per-test deadline: a stale peer
# on a fixed interop port, an orphaned `.zig-cache/o/*/test` process, or a
# silent partner parks the gate in a socket wait forever, and nothing here would
# ever return. Wrap each gate in the portable deadline runner so a true hang
# fails loud — naming the gate and the remediation — instead of wedging the run
# until a human kills it. The ceiling sits far above any healthy gate's
# wall-clock, so it only ever trips on a genuine wedge; override it with
# GATE_TIMEOUT for a slow runner.
GATE_TIMEOUT="${GATE_TIMEOUT:-20m}"

# Whether an exit code means "the deadline killed it" rather than "it failed".
# A function so it can be exercised directly: a grep for the two literals
# cannot tell a live branch from one someone left behind, and this is the half
# of the contract `tools/run-with-timeout-test.sh` does not reach from outside.
# Sourced by that test with GATES_SOURCE_ONLY set.
wedged_rc() {
  [ "$1" -eq 124 ] || [ "$1" -eq 137 ]
}

gate() {
  local rc=0
  python3 tools/run-with-timeout.py --kill-after 30s "$GATE_TIMEOUT" "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if wedged_rc "$rc"; then
      echo "ci/gates.sh: '$*' exceeded $GATE_TIMEOUT and was killed — likely a wedged socket wait" >&2
      echo "  (a stale peer on a fixed interop port, or an orphaned test process from a dead run)." >&2
      echo "  Sweep for orphans (pkill -f '.zig-cache/o/.*/test'), confirm no concurrent gate is running, and retry." >&2
    fi
    exit "$rc"
  fi
}

# Sourcing for the test above stops here; everything below is the sequence.
if [ -n "${GATES_SOURCE_ONLY:-}" ]; then return 0; fi

gate bash .devcontainer/post-create.sh
# The deadline wrapper bounds every gate below, and this sequence branches on
# the codes it returns, so its behaviour is checked before anything relies on
# it: exit codes, the signal a child actually receives, and no survivors.
gate bash tools/run-with-timeout-test.sh

gate zig build check
# Bounded mutation fuzzing over every surface that takes bytes somebody else
# chose. It stays out of `zig build check` because it spawns a nested
# `zig build`, and check's steps run in parallel over one cache — two builders
# racing that cache is the hazard .agents/rules/cli.md documents. Sequential
# here it is safe. The budget applies per target, so the cost grows with the
# number of targets rather than being split thinner among them.
gate zig build fuzz
# The two sidecars' own Rust unit tests. Both cover something no Zig test can
# reach: iroh's connect timeout actually firing, and the WebRTC inbound buffer
# making a fast sender wait rather than growing without limit. cargo is already
# on the path for the iroh steps below, so this adds a crate build and not a
# dependency.
gate zig build iroh-sidecar-test
gate zig build webrtc-sidecar-test
gate zig build bindings-fmt-check
gate zig build bindings
gate zig build racket-test
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
# The same live-Goblins conversation, once per binding. Without these the
# bindings are only ever proved against pancake's own checks, which cannot
# catch a binding that drifts from the protocol. These rows cover Deno, Python,
# Rust, and Racket against somebody else's implementation; Bun is dogfood-only.
gate zig build bindings-goblins-interop
gate zig build bindings-goblins-handoff
gate zig build bindings-goblins-gift
gate zig build goblins-handoff
# The gifter direction: pancake mints the signed desc:handoff-give and a live
# Goblins recipient must parse and redeem it. This is the only automated step
# that catches a pancake-side change to the signed give bytes (goblins-handoff
# forwards a Goblins-minted give verbatim, so it cannot).
gate zig build goblins-gift
# Live inbound op:gc-exports from Goblins after echo drops a near export — the
# one automated distributed-GC proof against somebody else's implementation.
gate zig build goblins-gc
# The listener direction for a binding: a Deno Host publishes an actor and a
# live Goblins vat dials it. Without this row every binding is only ever the
# client against Goblins.
gate zig build deno-goblins-listen
gate zig build fixture-gen-check
gate zig build ocapn-findings-check
gate zig build ocapn-conformance
gate zig build iroh-interop
# The cross-runtime relay matrix (ADR-0086): one shared harness proves TCP
# forwarding and the non-optional backpressure clause against every runtime's
# relay — the Deno reference relay, and the Python, Rust, and Racket relays. A
# runtime is a row, never a fork, so no binding can silently lack a proof
# (needs deno + uv + cargo; all three are already on PATH above).
gate zig build bindings-relay
# The matrix's iroh leg: each runtime's relay dials a real iroh endpoint over
# QUIC and carries the browser peer's live session through it. iroh-interop
# above already pays the cargo-iroh build, so the marginal cost is the wasm
# build and the deno-driven runs (needs deno + uv + cargo).
gate zig build bindings-relay-iroh
