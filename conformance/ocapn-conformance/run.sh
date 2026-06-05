#!/usr/bin/env bash
# Native entry point. Runs the upstream OCapN test suite via `uv` (the
# devcontainer provides uv/python) — no pixi/conda env. The suite deps
# (cryptography for Ed25519/gcrypt-shape primitives; stem for the onion
# netlayer) are materialized per-invocation by uv.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [ ! -e upstream/test_runner.py ]; then
    echo "OCapN test-suite submodule not initialized." >&2
    echo "Run: bash conformance/bootstrap-submodules.sh" >&2
    exit 1
fi
DEPS=(--python 3.12 --with 'cryptography>=42' --with 'stem>=1.8')
cmd="${1:-test}"; shift || true
cd upstream
case "$cmd" in
    test) exec uv run "${DEPS[@]}" python test_runner.py "$@" ;;
    smoke) exec uv run "${DEPS[@]}" python -c 'import test_runner; print("ocapn-conformance: env OK")' ;;
    shell) exec uv run "${DEPS[@]}" python ;;
    *) echo "usage: run.sh [test <ocapn-url>|smoke|shell]" >&2; exit 2 ;;
esac
