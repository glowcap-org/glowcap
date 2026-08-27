#!/usr/bin/env bash
# Keyed-relay rendezvous proof, native row: the installed pancake CLI
# cold-dials the registered peer's key designator through the reference relay
# (ADR-0088). The harness appends the target's complete hinted locator. A dead
# PANCAKE_RENDEZVOUS fallback proves the advertised route owns this dial.
set -euo pipefail
locator="$1"
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
out=$(PANCAKE_STATE="$state" PANCAKE_RENDEZVOUS="ws://127.0.0.1:1/relay" \
	./zig-out/bin/pancake ocapn call "$locator" greeter greet zig)
expected="hello zig, cold-dialed by rendezvous"
case "$out" in
*"$expected"*)
	echo "PASS: the native CLI used the locator's rendezvous-relay route instead of the dead PANCAKE_RENDEZVOUS fallback"
	exit 0
	;;
esac
echo "FAIL: unexpected output: $out"
exit 1
