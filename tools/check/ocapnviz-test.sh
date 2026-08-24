#!/usr/bin/env bash
# The bounded ocapnviz suite, as a member of `check`.
#
# The app carries hundreds of tests and, until this script, no `zig build` step
# ran a single one of them: `apps/ocapnviz/` is outside the root Deno scope and
# was absent from `build.zig`, so the only way to run them was to know the
# incantation and remember to type it. A suite nothing invokes is a suite that
# rots, and it rots invisibly, because every run a human does by hand is green
# right up until the one nobody did.
#
# Build, type, lint, and format checks live in ocapnviz-build-check.sh because
# they are cache-populating tool work, not a deterministic test deadline.
#
# This needs `deno`, which `check` otherwise does not, so it skips when deno is
# missing rather than failing — the same posture `c-abi-extract-matrix.sh` takes
# for the language ports it cannot find. A machine with deno gets the coverage;
# a Zig-only machine still gets a green hermetic gate, and says which it was.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$root/apps/ocapnviz"

if ! command -v deno >/dev/null 2>&1; then
	echo "ocapnviz-test: deno not on PATH, skipping the ocapnviz suite"
	exit 0
fi

if [ ! -d "$app" ]; then
	echo "ocapnviz-test: $app is missing" >&2
	exit 1
fi

cd "$app"
exec deno test -A
