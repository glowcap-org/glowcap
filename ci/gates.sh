#!/usr/bin/env bash
# The CI gate sequence, forge-neutral: the same commands a contributor runs.
# The checks workflow (.github/workflows/check.yml) runs this inside the
# committed devcontainer image. The sequence itself names no forge.
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
    # Name the gate on every failure, not only on a wedge. A gate's own output
    # is the tool's, and a tool that fails for an environment reason says
    # nothing about which of two dozen gates was running — so the sequence
    # says it, or the reader is left grepping a log for a command they cannot
    # identify.
    echo "ci/gates.sh: gate failed (exit $rc): $*" >&2
    if wedged_rc "$rc"; then
      echo "  It exceeded $GATE_TIMEOUT and was killed — likely a wedged socket wait" >&2
      echo "  (a stale peer on a fixed interop port, or an orphaned test process from a dead run)." >&2
      echo "  Sweep for orphans (pkill -f '.zig-cache/o/.*/test'), confirm no concurrent gate is running, and retry." >&2
    elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
      echo "  The command could not be run at all (not found, or not executable)." >&2
    else
      echo "  This is the gate's own failure, not the deadline's. Run it alone to see its output." >&2
    fi
    exit "$rc"
  fi
}

# Sourcing for the test above stops here; everything below is the sequence.
if [ -n "${GATES_SOURCE_ONLY:-}" ]; then return 0; fi

gate bash .devcontainer/hooks/post-create.sh
# The deadline wrapper bounds every gate below, and this sequence branches on
# the codes it returns, so its behaviour is checked before anything relies on
# it: exit codes, the signal a child actually receives, and no survivors.
gate bash tools/run-with-timeout-test.sh

gate zig build check
# The optional native secure-relay composition is deliberately absent from the
# base library graph, so `check` cannot prove it. Fetch the pinned Mbed TLS
# release by checksum and run both pollable and completion carriers through the
# real local certificate/refusal/close/resource matrix here.
gate zig build native-tls-build
# Bounded mutation fuzzing over every surface that takes bytes somebody else
# chose. It stays out of `zig build check` because it spawns a nested
# `zig build`, and check's steps run in parallel over one cache — two builders
# racing that cache is the hazard .agents/rules/cli.md documents. Sequential
# here it is safe.
#
# The run count is set here rather than left at the step's default, because the
# budget applies per target and the cost therefore grows with the number of
# targets. At the default the sweep runs for over an hour, which no per-gate
# deadline short enough to catch a wedged socket would ever admit — and an hour
# of CPU on every workflow run is not a proportionate thing to ask of a forge.
# What CI owes is that every target still builds and searches clean; depth is what a
# local or nightly run with a larger -Dfuzz-runs is for, and the escapes each
# target was validated against are recorded in its own header either way.
gate zig build fuzz -Dfuzz-runs=25K
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
# A real Chromium page registers its Wasm Host over local WSS/noise-relay; the
# installed native CLI cold-dials, fetches and calls it, while the relay audits
# that the CapTP canary never appeared outside the Noise channel.
gate zig build web-peer-test
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
# The same gifter proof with an opaque route hint in the handoff locator. This
# catches lossy hint decode/re-encode before a real Goblins recipient verifies
# the signed give.
gate zig build goblins-gift-hints
# The gifter direction in its harder position: the give arrives in a listener
# fire on a promise pancake introduced, rather than in an answer the recipient
# asked for. Only a live partner can say whether it reads one there.
gate zig build goblins-relayed-give
# The third handoff role: a live Goblins pair deposits into and withdraws from
# a *pancake* gift registry, so pancake answering both verbs is proved against
# somebody else's implementation rather than only the upstream suite.
gate zig build goblins-exporter
# Live inbound op:gc-exports from Goblins after echo drops a near export — the
# one automated distributed-GC proof against somebody else's implementation.
gate zig build goblins-gc
# The listener direction for a binding: a Deno Host publishes an actor and a
# live Goblins vat dials it. Without this row every binding is only ever the
# client against Goblins.
gate zig build deno-goblins-listen
# The relay's live-Goblins leg: a browser peer holds the keyed session through
# the byte-transparent reference relay. The relay links no codec, so a re-framed
# byte would fail the signed handshake against a real partner (needs deno +
# racket + goblins, and the wasm Host built above).
gate zig build goblins-relay
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
# Every native binding links the same relay archive, projects exact hostname
# and trust refusals from one local WSS fixture, then completes a call and its
# close barrier. This catches both ABI drift and foreign-static-link gaps.
gate zig build bindings-native-wss-relay
# The matrix's iroh leg: each runtime's relay dials a real iroh endpoint over
# QUIC and carries the browser peer's live session through it. iroh-interop
# above already pays the cargo-iroh build, so the marginal cost is the wasm
# build and the deno-driven runs (needs deno + uv + cargo).
gate zig build bindings-relay-iroh
