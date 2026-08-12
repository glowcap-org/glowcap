#!/usr/bin/env bash
# Live Rooms-over-onion proof. The harness owns Tor explicitly; pancake only
# receives configured SOCKS and control endpoints.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

command -v tor >/dev/null || { echo "demo-rooms-onion: tor is required" >&2; exit 127; }
command -v deno >/dev/null || { echo "demo-rooms-onion: deno is required" >&2; exit 127; }

state="$(mktemp -d)"
socks="$state/socks.sock"
control="$state/control.sock"
mkdir -p "$state/data"
printf '%s\n' \
  "DataDirectory $state/data" \
  "SocksPort unix:$socks" \
  "ControlPort unix:$control" \
  "CookieAuthentication 0" \
  "Log notice stdout" >"$state/torrc"

tor -f "$state/torrc" >"$state/tor.log" 2>&1 &
tor_pid=$!
cleanup() {
  kill "$tor_pid" 2>/dev/null || true
  wait "$tor_pid" 2>/dev/null || true
  rm -rf "$state"
}
trap cleanup EXIT

for _ in $(seq 1 600); do
  [ -S "$socks" ] && [ -S "$control" ] && break
  kill -0 "$tor_pid" 2>/dev/null || { cat "$state/tor.log" >&2; exit 1; }
  sleep 0.1
done
[ -S "$socks" ] && [ -S "$control" ] || {
  echo "demo-rooms-onion: Tor did not publish its endpoints" >&2
  cat "$state/tor.log" >&2
  exit 1
}

PANCAKE_ONION_SOCKS="$socks" PANCAKE_ONION_CONTROL="$control" \
  deno run --allow-ffi --allow-read --allow-net --allow-env \
  apps/rooms/demos/onion_demo.ts
