#!/usr/bin/env bash
# The ocapnviz suite, as a member of `check`.
#
# The app carries hundreds of tests and, until this script, no `zig build` step
# ran a single one of them: `apps/ocapnviz/` is outside the root Deno scope and
# was absent from `build.zig`, so the only way to run them was to know the
# incantation and remember to type it. A suite nothing invokes is a suite that
# rots, and it rots invisibly, because every run a human does by hand is green
# right up until the one nobody did.
#
# It needs `deno`, which `check` otherwise does not, so it skips when deno is
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

# The suite type-checks the modules a test imports, and nothing else.
# `Stage.tsx` has no test — there is no WebGL context to give one —
# so a type error in the scene code passed a green `deno test` right
# up until someone ran the app. `typecheck` starts from `main.tsx`,
# which reaches everything the browser loads.
#
# Formatting and lint join them for the same reason the suite did:
# this app is outside the root Deno scope, so `bindings-fmt-check`
# never sees it, and a check nobody invokes is a check that rots.
deno task typecheck
deno task fmt:check
deno lint
exec deno test -A
