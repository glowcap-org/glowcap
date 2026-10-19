#!/usr/bin/env bash
# Keyed-relay rendezvous proof, Zig CLI row: the installed glowcap CLI
# cold-dials the registered peer's key designator through the reference relay
# (ADR-0034). The harness appends the target's complete hinted locator. A dead
# GLOWCAP_RENDEZVOUS fallback proves the advertised route owns this dial.
set -euo pipefail
locator="$1"
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
out=$(GLOWCAP_STATE="$state" GLOWCAP_RENDEZVOUS="ws://127.0.0.1:1/relay" \
	./zig-out/bin/glowcap ocapn call "$locator" greeter greet zig)
expected="hello zig, cold-dialed by rendezvous"
case "$out" in
*"$expected"*)
	echo "PASS: the installed Zig CLI used the locator's rendezvous-relay route instead of the dead GLOWCAP_RENDEZVOUS fallback"
	exit 0
	;;
esac
echo "FAIL: unexpected output: $out"
exit 1
