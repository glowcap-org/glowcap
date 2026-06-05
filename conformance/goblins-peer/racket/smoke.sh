#!/usr/bin/env bash
# Boot seven-caps-peer.rkt, grep the printed ocapn:// URL, probe
# TCP 22045, kill the peer, exit. The TCP probe avoids false-green
# if Goblins dies between printing the URL and registering caps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG="$(mktemp)"

# Boot the peer in the background. Redirect both fds to the log so
# we can grep for the printed URL without losing stderr context if
# the peer crashes.
racket seven-caps-peer.rkt >"$LOG" 2>&1 &
PEER_PID=$!
cleanup() {
    kill "$PEER_PID" 2>/dev/null || true
    rm -f "$LOG"
}
trap cleanup EXIT

# Wait up to 30s for the URL to appear. The peer prints the
# `ocapn://...tcp-testing-only?...` URL after registry-registration
# completes; greppable evidence of liveness.
URL_TIMEOUT=30
URL_FOUND=""
for _ in $(seq 1 "$URL_TIMEOUT"); do
    if grep -q "ocapn://.*tcp-testing-only" "$LOG"; then
        URL_FOUND="yes"
        break
    fi
    sleep 1
done
if [ -z "$URL_FOUND" ]; then
    echo "smoke: peer did not print ocapn:// URL within ${URL_TIMEOUT}s" >&2
    echo "--- peer log ---" >&2
    cat "$LOG" >&2
    exit 1
fi

# Probe 127.0.0.1:22045 (seven-caps-peer.rkt default).
# `nc -z` (zero-IO scan) returns 0 on accepted connection.
PORT_TIMEOUT=10
PORT_BOUND=""
for _ in $(seq 1 "$PORT_TIMEOUT"); do
    if nc -z 127.0.0.1 22045 2>/dev/null; then
        PORT_BOUND="yes"
        break
    fi
    sleep 1
done
if [ -z "$PORT_BOUND" ]; then
    echo "smoke: TCP port 22045 not accepting connections within ${PORT_TIMEOUT}s" >&2
    echo "--- peer log ---" >&2
    cat "$LOG" >&2
    exit 1
fi

echo "smoke: seven-caps-peer.rkt is live on 127.0.0.1:22045 (URL printed, port bound)"
exit 0
