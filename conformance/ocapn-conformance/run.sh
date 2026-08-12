#!/usr/bin/env bash
# Native entry point. Runs the upstream OCapN test suite via `uv` (the
# devcontainer provides uv/python). The suite deps are materialized from this
# directory's committed uv lock, including integrity hashes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [ ! -e upstream/test_runner.py ]; then
    echo "OCapN test-suite submodule not initialized." >&2
    echo "Run: bash conformance/bootstrap-submodules.sh" >&2
    exit 1
fi
cmd="${1:-test}"; shift || true
cd upstream
case "$cmd" in
    test) exec uv run --project .. --locked python test_runner.py "$@" ;;
    smoke) exec uv run --project .. --locked python -c 'import test_runner; print("ocapn-conformance: env OK")' ;;
    shell) exec uv run --project .. --locked python ;;
    *) echo "usage: run.sh [test <ocapn-url>|smoke|shell]" >&2; exit 2 ;;
esac
