#!/usr/bin/env bash
# The register half of the rendezvous, natively (ADR-0088).
#
# The sibling rows prove the *dialing* half: a consumer cold-dials a peer that
# registered at a relay. This proves the other side — a native pancake CLI is
# the peer that registers. It binds no listening socket at all; it holds an
# inbound socket at the relay under its key designator, prints the
# `keyed-relay` locator that names it, and answers a partner that arrives
# through the bridge. That is the shape a process behind a NAT needs, and
# until this row existed the CLI could dial a rendezvous but never join one.
#
# Self-contained on purpose: this row owns three processes whose lifetimes
# interlock (relay, registrant, client), where the sibling rows' harness
# supplies a registrant of its own.
set -euo pipefail
cd "$(dirname "$0")/../../.."

relay_log=$(mktemp)
host_log=$(mktemp)
host_state=$(mktemp -d)
client_state=$(mktemp -d)
relay_pid=""
host_pid=""
cleanup() {
	[ -n "$relay_pid" ] && kill "$relay_pid" 2>/dev/null || true
	[ -n "$host_pid" ] && kill "$host_pid" 2>/dev/null || true
	rm -rf "$host_state" "$client_state" "$relay_log" "$host_log"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $1"
	echo "--- registrant log ---"
	cat "$host_log" || true
	exit 1
}

# The reference relay, on an ephemeral port it reports.
deno run --allow-net --allow-ffi --allow-env --allow-read \
	bindings/ts/relay/serve.ts 0 >"$relay_log" 2>&1 &
relay_pid=$!
for _ in $(seq 1 60); do
	grep -q "DENO-RELAY-READY" "$relay_log" && break
	sleep 0.2
done
grep -q "DENO-RELAY-READY" "$relay_log" || fail "relay never reported ready"
port=$(grep "DENO-RELAY-READY" "$relay_log" | awk '{print $2}')

# The registrant: no bind, a relay registration instead. `--publish` answers
# one partner and exits, which is the whole conversation this row needs.
PANCAKE_STATE="$host_state" ./zig-out/bin/pancake --json ocapn listen \
	--rendezvous "ws://127.0.0.1:${port}/register" --publish greeter >"$host_log" 2>&1 &
host_pid=$!
for _ in $(seq 1 60); do
	grep -q "ocapn://" "$host_log" && break
	sleep 0.2
done
locator=$(grep -o 'ocapn://[^"]*' "$host_log" | head -1)
[ -n "$locator" ] || fail "registrant never printed a locator"
case "$locator" in
*.keyed-relay) ;;
*) fail "registrant printed a non-rendezvous locator: $locator" ;;
esac

# The client cold-dials that identity through the same relay.
out=$(PANCAKE_STATE="$client_state" PANCAKE_RENDEZVOUS="ws://127.0.0.1:${port}/relay" \
	./zig-out/bin/pancake --json ocapn call "$locator" greeter greet registered 2>&1) || true
case "$out" in
*"Hello, registered"*)
	echo "PASS: a native CLI registered at the relay and answered a cold dial - no listening socket, reached by key designator alone"
	exit 0
	;;
esac
fail "unexpected client output: $out"
