#!/usr/bin/env bash
# run-seams.sh — runs all five pancake<->Spritely-Goblins interop "seam"
# stacks and reports pass/fail for each. These are the durable form of
# the proofs developed interactively; see SEAM-MATRIX.md.
#
# Each stack pairs canonical Spritely Goblins with pancake substituted
# at one or both seams (OCapN/CapTP via captp.rkt; netlayer via a
# pancake-backed netlayer). A stack PASSES when an echo cap round-trips
# across the wire between the two peers.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"

RK="${RACKET:-$HOME/.cache/pancake-non-pixi-lazy-install/racket-8.16/bin/racket}"
export PLTUSERHOME="${PLTUSERHOME:-$HOME/.cache/pancake-non-pixi-lazy-install/racket-8.16/userhome}"
T="$(cd ../../../.. && pwd)/target/release"
export PANCAKE_LIB="${PANCAKE_LIB:-$T/libpancake_ffi_runtime.so}"
export PANCAKE_NET_TCP_LIB="${PANCAKE_NET_TCP_LIB:-$T/libpancake_ffi_net_tcp.so}"
export PANCAKE_NET_IROH_LIB="${PANCAKE_NET_IROH_LIB:-$T/libpancake_ffi_net_iroh.so}"

pass=0; fail=0
report () { if [ "$1" = "ok" ]; then echo "  PASS: $2"; pass=$((pass+1)); else echo "  FAIL: $2"; fail=$((fail+1)); fi; }

# Two-process helper: $1=host script, $2=client script, $3=marker, $4=label, $5=pre (optional)
run_pair () {
  local host="$1" client="$2" marker="$3" label="$4" pre="${5:-}"
  [ -n "$pre" ] && eval "$pre"
  timeout 70 "$RK" "$host" >/tmp/seam-host.log 2>&1 & local hp=$!
  sleep 6
  local out; out="$(timeout 45 "$RK" "$client" 2>&1)"
  kill "$hp" 2>/dev/null; wait "$hp" 2>/dev/null
  if echo "$out" | grep -q "$marker"; then report ok "$label"; else report fail "$label"; echo "$out" | tail -4; fi
}

echo "=== Stack 4: stock Goblins <-> stock Goblins over pancake iroh ==="
if timeout 45 "$RK" seams/seam4-loopback.rkt 2>&1 | grep -q "STACK4-LOOPBACK-OK"; then report ok "stack4 (iroh, stock<->stock)"; else report fail "stack4"; fi

echo "=== Stack 3: stock-Goblins client <-> pancake-captp host over pancake TLS ==="
run_pair seams/seam3-host.rkt seams/seam3-client.rkt "STACK3-TLS-OK" "stack3 (tcp-tls, pancake-OCapN<->stock)"

echo "=== Stack 5: stock-Goblins client <-> pancake-captp host over pancake iroh ==="
run_pair seams/seam5-host.rkt seams/seam5-client.rkt "STACK5-IROH-OK" "stack5 (iroh, pancake-OCapN<->stock)" "rm -f /tmp/stack5-host.addr"

echo "=== Stack 2: stock-Goblins client <-> pancake-captp host over Racket sockets ==="
# seam2 scripts take a port arg; host on 22262
timeout 70 "$RK" seams/seam2-host.rkt 22262 >/tmp/seam-host.log 2>&1 & HP=$!
sleep 6
S2="$(timeout 45 "$RK" seams/seam2-client.rkt 22262 2>&1)"
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
if echo "$S2" | grep -qiE 'hello.*world'; then report ok "stack2 (racket-sockets, pancake-OCapN<->stock)"; else report fail "stack2"; echo "$S2" | tail -4; fi

echo "============================================================"
echo "SEAMS: $pass passed, $fail failed (stack 1 = canonical Spritely, baseline)"
[ "$fail" -eq 0 ] && echo "ALL SEAMS GREEN" || exit 1
