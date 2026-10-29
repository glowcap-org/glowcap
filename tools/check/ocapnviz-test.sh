#!/usr/bin/env bash
# The bounded ocapnviz suite, as a member of `runtime-check`.
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
# That phase checks test modules with --no-run; this phase only executes them.
#
# Test files run in parallel. Run one after another, each file's isolate
# startup cost more than its tests, and the suite outgrew the per-step
# deadline. A test that reads back persisted state installs its own memory
# storage (src/state/memory-storage.ts), since Deno's localStorage is one
# SQLite file shared by every worker.
#
# Deno is part of the declared in-tree toolchain. A missing runtime is a failed
# precondition, not a green test with less coverage.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$root/apps/ocapnviz"

if [ ! -d "$app" ]; then
	echo "ocapnviz-test: $app is missing" >&2
	exit 1
fi

cd "$app"
exec deno test -A --no-check --parallel
