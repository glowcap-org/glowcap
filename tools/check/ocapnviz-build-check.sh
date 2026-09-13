#!/usr/bin/env bash
# Type-check, format-check, lint, and production-build ocapnviz. These are
# build-tool work rather than a bounded test process; ocapnviz-test.sh owns the
# separately timed suite.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$root/apps/ocapnviz"

if [ ! -d "$app" ]; then
	echo "ocapnviz-build-check: $app is missing" >&2
	exit 1
fi

cd "$app"
log=$(mktemp "${TMPDIR:-/tmp}/ocapnviz-build-check.XXXXXX")
trap 'rm -f "$log"' EXIT
if ! {
	deno task typecheck
	deno task fmt:check
	deno lint
	deno task build
} >"$log" 2>&1; then
	cat "$log" >&2
	exit 1
fi
test -f dist/glowcap_host.wasm || {
	echo "ocapnviz-build-check: production bundle omitted glowcap_host.wasm" >&2
	exit 1
}
