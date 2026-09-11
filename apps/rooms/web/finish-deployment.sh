#!/bin/sh
# The build graph runs this after every mounted artifact is complete. The
# deployment checks both the checkout and the selected browser generation.
set -eu
cd "$(dirname "$0")/../../.."
revision=$(git rev-parse --short=12 HEAD)
if [ -n "$(git status --porcelain)" ]; then
	revision="$revision-dirty"
fi
browser_version=$(cat zig-out/rooms-web/current/source.version)
case "$browser_version" in
	*[!0-9a-f]* | '') echo "rooms: prepared browser identity is malformed" >&2; exit 1 ;;
esac
[ "${#browser_version}" -eq 64 ] || { echo "rooms: prepared browser identity is malformed" >&2; exit 1; }
staged=$(mktemp zig-out/.rooms-deployment.XXXXXXXX)
trap 'rm -f "$staged"' EXIT HUP INT TERM
printf '%s\n%s\n' "$revision" "$browser_version" > "$staged"
mv "$staged" zig-out/rooms-deployment.version
