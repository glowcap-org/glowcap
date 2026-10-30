#!/usr/bin/env bash
# The CI gate sequence, forge-neutral: the same commands a contributor runs.
# The checks workflow (.github/workflows/check.yml) runs this inside the
# committed devcontainer image. The sequence itself names no forge.
# With no argument, run every phase in order. A phase argument selects only
# that phase for the parallel CI jobs; each writes separate evidence.
# `--compile-only <k/n> <phase>...` compiles the k-th of n slices of what those
# phases would run and runs nothing: each `zig build` gate gets -Dcompile-only
# and -Dcompile-shard, which rewire its steps to their share of its compile
# half, and every other command is skipped. CI's n build jobs for a group run
# it so the test jobs that run the same phases find their compiles cached. It
# writes no evidence record, because nothing was checked. Exits 2 on an
# unknown phase or a malformed shard.
# The script runs the isolated, runtime, infrastructure, and outside-authority
# gates in order. The wider sibling inventory in docs/build-steps.md stays
# excluded until its CI cost earns recurring execution.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Each unit or process proof owns its focused deadline. This wider deadline
# contains a build-graph, setup, or cleanup wedge that falls outside those
# boundaries. It names the gate and leaves no child behind. Override it with
# GATE_TIMEOUT when measuring a slower runner.
#
# A hosted runner compiles cold, an order of magnitude slower than a warm
# workstation, so a deadline sized on a workstation is a failure waiting for
# CI. A `build` line names a gate whose time is mostly that cold compile and
# gives it BUILD_TIMEOUT. A phase opens with one when its proofs share a heavy
# build, so each proof's deadline times the proof. Per-test limits stay
# unchanged inside both. The cold `check-build` takes about 30 minutes on a
# two-CPU runner, and BUILD_TIMEOUT gives it twice that.
BUILD_TIMEOUT="${BUILD_TIMEOUT:-${GATE_TIMEOUT:-60m}}"
# A `long` line names a gate that serializes many process proofs, each under
# its own deadline, so its healthy duration on a two-CPU runner is itself
# tens of minutes. It gets LONG_TIMEOUT, twice its measured hosted-runner
# time, so the wedge detector still fires while a healthy run keeps headroom.
LONG_TIMEOUT="${LONG_TIMEOUT:-${GATE_TIMEOUT:-40m}}"
# Resolve specialized defaults before assigning the ordinary default.
GATE_TIMEOUT="${GATE_TIMEOUT:-20m}"

# Whether an exit code means "the deadline killed it" rather than "it failed".
# A function so it can be exercised directly: a grep for the two literals
# cannot tell a live branch from one someone left behind, and this is the half
# of the contract `tools/run-with-timeout-test.sh` does not reach from outside.
# Sourced by that test with GATES_SOURCE_ONLY set.
wedged_rc() {
  [ "$1" -eq 124 ] || [ "$1" -eq 137 ]
}

# Keep the literal gate inventory below authoritative for both local runs and CI.
phase() { current_phase=$1; }

# A failed gate does not stop the sequence: every later gate still runs, so
# one run reports every failure, and the sequence exits with the first. A gate
# that needed a failed build fails fast on the same compile error. A build
# that ran out of time ends the phase, because every later gate in it needs
# that build.
first_failure=0
compile_only=false
compile_shard=1/1
# Phases that share a build each open with it, so a compile-only job sees the
# same command once per phase. One run of it fills the cache for all of them.
compiled=$'\n'
selected_phases=()

gate() { run_gate "$GATE_TIMEOUT" continue "$@"; }
long() { run_gate "$LONG_TIMEOUT" continue "$@"; }
build() { run_gate "$BUILD_TIMEOUT" stop "$@"; }

run_gate() {
  local timeout=$1 on_deadline=$2
  shift 2
  if ! phase_selected "${current_phase:-}"; then
    return 0
  fi
  local rc=0
  local -a command=("$@")
  if [ "$compile_only" = true ]; then
    [ "${1:-}" = zig ] && [ "${2:-}" = build ] || return 0
    # A compile has no run to time, so every gate gets the build deadline,
    # and the summary names what this job compiled rather than reused.
    timeout=$BUILD_TIMEOUT
    command=(zig build -Dcompile-only "-Dcompile-shard=$compile_shard" --summary new "${@:3}")
    case "$compiled" in *$'\n'"${command[*]}"$'\n'*) return 0 ;; esac
    compiled+="${command[*]}"$'\n'
  elif [ "${1:-}" = zig ] && [ "${2:-}" = build ]; then
    local has_test_timeout=false has_summary=false arg
    for arg in "${@:3}"; do
      [ "$arg" = -- ] && break
      [ "$arg" != --test-timeout ] || has_test_timeout=true
      [ "$arg" != --summary ] || has_summary=true
    done
    command=(zig build)
    if [ "$has_test_timeout" = false ]; then
      command+=(--test-timeout 30s)
    fi
    # New work is visible in test jobs too: unexpected recompilation after
    # restoring a group's compiled state must not disappear into a quiet log.
    if [ "$has_summary" = false ]; then
      command+=(--summary new)
    fi
    command+=("${@:3}")
  fi
  local began=$SECONDS
  printf 'ci/gates.sh: starting: %s\n' "${command[*]}" >&2
  python3 tools/run-with-timeout.py --kill-after 30s --heartbeat 60s "$timeout" "${command[@]}" || rc=$?
  printf '%s\t%s\t%s\n' "$rc" "$((SECONDS - began))" "${command[*]}" >>"$EVIDENCE_ROWS"
  if [ "$rc" -ne 0 ]; then
    # Name the gate on every failure, not only on a wedge. A gate's own output
    # is the tool's, and a tool that fails for an environment reason says
    # nothing about which of two dozen gates was running — so the sequence
    # says it, or the reader is left grepping a log for a command they cannot
    # identify.
    echo "ci/gates.sh: gate failed (exit $rc): ${command[*]}" >&2
    if wedged_rc "$rc"; then
      echo "  It exceeded $timeout and was killed." >&2
      echo "  Inspect the named gate's last output and any process still holding its port before retrying." >&2
      if [ "$on_deadline" = stop ]; then
        echo "  Every later gate in this phase needs this build, so the phase stops here." >&2
        exit "$rc"
      fi
    elif [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
      echo "  The command could not be run at all (not found, or not executable)." >&2
    else
      echo "  This is the gate's own failure, not the deadline's. Run it alone to see its output." >&2
    fi
    [ "$first_failure" -eq 0 ] && first_failure=$rc
    return 0
  fi
  printf 'ci/gates.sh: passed (%ss): %s\n' "$((SECONDS - began))" "${command[*]}" >&2
}

phase_selected() {
  local candidate
  [ "${#selected_phases[@]}" -eq 0 ] && return 0
  for candidate in "${selected_phases[@]}"; do
    [ "$candidate" = all ] || [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

# Sourcing for the test above stops here; everything below is the sequence.
if [ -n "${GATES_SOURCE_ONLY:-}" ]; then return 0; fi

if [ "${1:-}" = --compile-only ]; then
  compile_only=true
  compile_shard=${2:-}
  [[ "$compile_shard" =~ ^[1-9][0-9]*/[1-9][0-9]*$ ]] && [ "${compile_shard%/*}" -le "${compile_shard#*/}" ] ||
    { echo "ci/gates.sh: --compile-only needs a k/n shard with 1 <= k <= n" >&2; exit 2; }
  shift 2
  [ "$#" -gt 0 ] || { echo "ci/gates.sh: --compile-only needs at least one phase" >&2; exit 2; }
elif [ "$#" -gt 1 ]; then
  echo "ci/gates.sh: expected at most one phase" >&2
  exit 2
fi
selected_phases=("$@")
# The phase lines below are the only list of phases.
known_phases=" all $(sed -n 's/^phase \([a-z0-9-]*\)$/\1/p' "${BASH_SOURCE[0]}" | tr '\n' ' ')"
# bash 3.2 (the macOS host) calls an empty array unbound under set -u.
for selected_phase in ${selected_phases[@]+"${selected_phases[@]}"}; do
  case "$known_phases" in
    *" $selected_phase "*) ;;
    *) echo "ci/gates.sh: unknown phase: $selected_phase" >&2; exit 2 ;;
  esac
done
selected_phase=${1:-all}

# Every gate above appends its exit and duration here, and the exit trap turns
# the rows into the evidence record (tools/evidence/record.py) however the
# sequence ends. A green sequence whose record step fails exits 70: a check
# without its record is not evidence.
EVIDENCE_ROWS=$(mktemp)
EVIDENCE_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
finish() {
  local rc=$?
  if [ "$compile_only" = true ]; then
    rm -f -- "$EVIDENCE_ROWS"
    exit "$rc"
  fi
  local outcome=failed
  [ "$rc" -eq 0 ] && outcome=passed
  local record_rc=0
  local -a destination=(--note)
  if [ "$selected_phase" != all ]; then
    destination=(--out "zig-out/evidence/$selected_phase")
  fi
  python3 tools/evidence/record.py --gates "$EVIDENCE_ROWS" \
    --started "$EVIDENCE_STARTED" --outcome "$outcome" "${destination[@]}" || record_rc=$?
  if [ "$record_rc" -ne 0 ]; then
    echo "ci/gates.sh: the evidence record step failed (exit $record_rc), see above" >&2
    [ "$rc" -eq 0 ] && rc=70
  fi
  rm -f -- "$EVIDENCE_ROWS"
  exit "$rc"
}
trap finish EXIT

# The source contracts, formatting among them, compile only their checkers,
# so CI runs them in a group with no build job that reports within minutes of
# a push instead of behind the product compile.
phase source
gate zig build source-check
phase infrastructure
gate bash .devcontainer/hooks/post-create.sh
# Coding-agent downloads run in .github/workflows/agent-tools.yml. Product
# validation needs the toolchain, not an available coding-agent vendor.
# The deadline wrapper bounds every gate below, and this sequence branches on
# the codes it returns, so its behaviour is checked before anything relies on
# it: exit codes, the signal a child actually receives, and no survivors.
gate bash tools/run-with-timeout-test.sh

gate zig build infrastructure-check
phase core
build zig build check-build
gate zig build check
phase memcheck
build zig build test-memcheck-build
long zig build test-memcheck
# The process, application, and language-workspace proofs, run against the
# ReleaseSafe archives a release ships (tools/build/release.zig refuses Debug).
# The core phase's Debug tests still meet Debug's undefined-memory fill on
# every change.
phase runtime
build zig build runtime-check-build -Doptimize=ReleaseSafe
long zig build runtime-check -Doptimize=ReleaseSafe
# The optional Mbed TLS relay composition is deliberately absent from the
# base library graph, so `check` cannot prove it. Fetch the pinned Mbed TLS
# release by checksum and run both pollable and completion carriers through the
# real local certificate/refusal/close/resource matrix independently of the
# product build, so a carrier failure reports without waiting for Rooms.
phase tls
gate zig build relay-tls-build
phase shipped
# Bound optimizer memory without dropping a test layer. The workflow contract
# checks this partition against the Layer enum in test/all_test.zig.
build zig build test -Doptimize=ReleaseSafe -Dtest-layer=loam,root,foundation,codec,model
build zig build test -Doptimize=ReleaseSafe -Dtest-layer=engine,session,actors,c_abi
build zig build test -Doptimize=ReleaseSafe -Dtest-layer=driver,net
phase smoke
# Representative browser and outside-authority proofs run on every change.
gate zig build wasm-driver-test
gate zig build wasm-abi-layout-check
gate zig build wasm-import-check
gate zig build web-peer-test
gate zig build goblins-interop
# Bounded mutation fuzzing over every surface that takes bytes somebody else
# chose. It stays out of `zig build check` because it spawns a nested
# `zig build`, and check's steps run in parallel over one cache — two builders
# racing that cache is the hazard the build lease exists to prevent. Sequential
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
#
# Each target compiles its own ReleaseSafe binary, which a cold hosted runner
# pays in full, so the sweep's time grows with every target added. It runs as
# interleaved shards, each a phase of its own so CI runs them in parallel.
# When a shard's headroom warning fires, add a shard here.
phase fuzz-1
gate zig build fuzz -Dfuzz-runs=25K -Dfuzz-shard=1/4
phase fuzz-2
gate zig build fuzz -Dfuzz-runs=25K -Dfuzz-shard=2/4
phase fuzz-3
gate zig build fuzz -Dfuzz-runs=25K -Dfuzz-shard=3/4
phase fuzz-4
gate zig build fuzz -Dfuzz-runs=25K -Dfuzz-shard=4/4
# The Rust sidecars' own unit tests. The shared crate proves a private-runtime
# call survives an ambient Tokio runtime and that the release barrier keeps a
# dropped task's failure; the two sidecars each cover something no Zig test can
# reach: iroh's connect timeout actually firing, and the WebRTC inbound buffer
# making a fast sender wait rather than growing without limit. cargo is already
# on the path for the iroh steps below, so this adds crate builds and not a
# dependency.
phase sidecars
gate zig build sidecar-common-test
gate zig build iroh-sidecar-test
gate zig build webrtc-sidecar-test
# Host adoption of many DataChannels on one loop thread, and three-party redeem
# over a bare webrtc designator through the configured signaling authority.
phase bindings
gate zig build webrtc-loop
gate zig build webrtc-redeem
# Clippy compiles every first-party crate and its dependencies, so on a cold
# runner its time is the compile. The format check below reuses that cache.
build zig build rust-lint
gate zig build bindings-fmt-check
gate zig build bindings
# Checkout consumers cannot catch files omitted from a published package.
gate zig build bindings-package-check
gate zig build bindings-noise-relay-listen
# The verb spine and every other hermetic proof family, because a proof no
# gate runs rots.
gate zig build bindings-verb-spine
gate zig build bindings-keyed-tcp-restart
gate zig build bindings-keyed-relay-rendezvous
# The Zig CLI registers at the reference relay with no listening socket and
# answers a cold dial.
gate zig build zig-keyed-relay-register
gate zig build bindings-iroh-handoff
gate zig build bindings-iroh-redeem-posture
gate zig build racket-test
phase browser
# The Rooms browser application and the Loam browser consumer are cargo and
# Wasm builds every proof below shares.
build zig build loam-browser-build rooms-web-build
build zig build rooms-archive-build rooms-session-build iroh-abi
# Shared storage changes must preserve the Rust/Wasm consumer's IndexedDB
# transactions, cold restoration and capability custody in a real browser.
gate zig build loam-browser-test
gate zig build rooms-rust-browser-test
# The production Rooms page is a peer, and every supported browser journey is
# release evidence rather than an opt-in demo. The family runs concurrently
# within a shard and grows with every journey, so like the fuzz sweep it runs
# as interleaved shards, each a phase that opens with the shared builds. When a
# shard's headroom warning fires, add a shard.
phase browser-proofs-1
build zig build loam-browser-build rooms-web-build
build zig build rooms-archive-build rooms-session-build iroh-abi
gate zig build rooms-web-proofs -Drooms-web-proof-shard=1/4
phase browser-proofs-2
build zig build loam-browser-build rooms-web-build
build zig build rooms-archive-build rooms-session-build iroh-abi
gate zig build rooms-web-proofs -Drooms-web-proof-shard=2/4
phase browser-proofs-3
build zig build loam-browser-build rooms-web-build
build zig build rooms-archive-build rooms-session-build iroh-abi
gate zig build rooms-web-proofs -Drooms-web-proof-shard=3/4
phase browser-proofs-4
build zig build loam-browser-build rooms-web-build
build zig build rooms-archive-build rooms-session-build iroh-abi
gate zig build rooms-web-proofs -Drooms-web-proof-shard=4/4
phase rooms-interop
# The C ABI archives and the Rooms services every live proof below dials.
build zig build build rooms-archive-build
# The smallest outside-authority Rooms proof: a real Goblins vat and a Rooms
# glowcap member exchange room traffic while the server records the Goblins
# session on syrup/v1_0 and the glowcap session on capnp/next. This needs no
# browser or iroh build, so it belongs in the recurring sequence rather than
# being hidden behind the heavyweight Rooms matrix.
gate zig build goblins-rooms
# Every one-shot client in one room: Deno, Python, Racket, Rust, and Zig each
# enter, wait for the whole roster, post, and hear every other member. The
# room contract has one TypeScript reader and four hand-written ones; this is
# where a client still holding an old contract fails (needs deno + python3 +
# racket + cargo, all on PATH above).
gate zig build demo-rooms
# Both shipped IRC edges with a real outside implementation: fixture IRC ↔
# bridge ↔ Goblins, then ordinary IRC client ↔ front ↔ Rooms room ↔ Goblins,
# including a reply over the direct session the IRC side initiated.
gate zig build goblins-rooms-irc
phase interop
build zig build build rooms-archive-build
# The same live-Goblins conversation, once per binding. Without these the
# bindings are only ever proved against glowcap's own checks, which cannot
# catch a binding that drifts from the protocol. These rows cover Deno, Python,
# Rust, and Racket against somebody else's implementation; Bun is dogfood-only.
gate zig build bindings-goblins-interop
gate zig build bindings-goblins-handoff
gate zig build bindings-goblins-gift
gate zig build goblins-handoff
# The encrypted counterpart also changes the exporter's advertised routing
# advice between the gifter and recipient sessions.
gate zig build goblins-handoff-iroh
# The gifter direction: glowcap mints the signed desc:handoff-give and a live
# Goblins recipient must parse and redeem it. This is the only automated step
# that catches a glowcap-side change to the signed give bytes (goblins-handoff
# forwards a Goblins-minted give verbatim, so it cannot).
gate zig build goblins-gift
# The same gifter proof with an opaque route hint in the handoff locator. This
# catches lossy hint decode/re-encode before a real Goblins recipient verifies
# the signed give.
gate zig build goblins-gift-hints
# The gifter direction in its harder position: the give arrives in a listener
# fire on a promise glowcap introduced, rather than in an answer the recipient
# asked for. Only a live partner can say whether it reads one there.
gate zig build goblins-relayed-give
# The reciprocal foreign-promise direction: Goblins hands glowcap an
# unresolved promise, then the owning Session installs listenTo before asking
# Goblins to settle it with a callable capability nested in the value.
gate zig build goblins-listen-recipient
# The third handoff role: a live Goblins pair deposits into and withdraws from
# a *glowcap* gift registry, so glowcap answering both verbs is proved against
# somebody else's implementation rather than only the upstream suite.
gate zig build goblins-exporter
# Live GC in both directions: Goblins releases a glowcap export, then its
# weak reference observes reclamation after the owning Zig Session releases.
gate zig build goblins-gc
# The listener direction for every FFI binding: each Host publishes an actor
# and a live Goblins vat dials, enlivens, and calls it. This is the reciprocal
# half of bindings-goblins-interop, which has the bindings dial Goblins.
gate zig build bindings-goblins-listen
# The relay's live-Goblins leg: a browser peer holds the keyed session through
# the byte-transparent reference relay. The relay links no codec, so a re-framed
# byte would fail the signed handshake against a real partner (needs deno +
# racket + goblins, and the wasm Host built above).
gate zig build goblins-relay
gate zig build fixture-gen-check
gate zig build ocapn-findings-check
gate zig build ocapn-conformance-next
gate zig build goblins-glowcap-pair-gift
phase transports
# The C ABI archives and the iroh transport every proof below links.
build zig build build iroh-lib iroh-abi
gate zig build iroh-interop
# The provider seam (ADR-0024) in every FFI runtime: the C driver, the
# Python binding, and the Rust binding each install an iroh provider package
# and dial a real endpoint through it. A binding that closes its endpoint
# under the driver's lease, or holds an accepted session without serving it,
# fails here and nowhere in `check`; iroh-interop above already pays the
# cargo-iroh build (needs cargo + python3).
gate zig build iroh-driver-provider
gate zig build python-iroh-driver-provider
gate zig build rust-iroh-driver-provider
# The cross-runtime relay matrix (ADR-0033): one shared harness proves TCP
# forwarding and the non-optional backpressure clause against every runtime's
# relay — the Deno reference relay, and the Python, Rust, and Racket relays. A
# runtime is a row, never a fork, so no binding can silently lack a proof
# (needs deno + uv + cargo; all three are already on PATH above).
gate zig build bindings-relay
# Every language binding links the same relay archive, projects exact hostname
# and trust refusals from one local WSS fixture, then completes a call and its
# close barrier. This catches both ABI drift and foreign-static-link gaps.
gate zig build bindings-wss-relay
# The matrix's iroh leg: each runtime's relay dials a real iroh endpoint over
# QUIC and carries the browser peer's live session through it. iroh-interop
# above already pays the cargo-iroh build, so the marginal cost is the wasm
# build and the deno-driven runs (needs deno + uv + cargo).
gate zig build bindings-relay-iroh

# Every gate ran. Report the first failure, if any.
exit "$first_failure"
