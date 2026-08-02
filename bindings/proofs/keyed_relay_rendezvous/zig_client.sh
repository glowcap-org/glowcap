#!/usr/bin/env bash
# Keyed-relay rendezvous proof, native row: the installed pancake CLI
# cold-dials the registered peer's key designator through the reference relay
# (ADR-0088). The harness appends `<relay-port> <designator>` to this argv.
# PANCAKE_RENDEZVOUS carries the dialing host's relay mapping — deployment
# configuration, never locator bytes — and PANCAKE_STATE keeps the minted
# identity hermetic to this run.
set -euo pipefail
port="$1"
designator="$2"
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
out=$(PANCAKE_STATE="$state" PANCAKE_RENDEZVOUS="ws://127.0.0.1:${port}/relay" \
	./zig-out/bin/pancake ocapn call "ocapn://${designator}.keyed-relay" greeter greet zig)
expected="hello zig, cold-dialed by rendezvous"
case "$out" in
*"$expected"*)
	echo "PASS: the native CLI cold-dialed a registered peer by rendezvous - the core classified the keyed-relay locator, PANCAKE_RENDEZVOUS opened the relay leg, and the keyed session answered"
	exit 0
	;;
esac
echo "FAIL: unexpected output: $out"
exit 1
