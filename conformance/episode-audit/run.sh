#!/usr/bin/env bash
# Native entry point. Runs audit.rkt against the sibling
# accountability-on-goblins/.data/ with racket on PATH (devcontainer).
# Note: audit.rkt's crypto FFI needs libsodium + libblake3 available to
# racket; the devcontainer's Racket/Goblins install provides the Goblins
# crypto stack.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
DATA="$(cd ../accountability-on-goblins/.data 2>/dev/null && pwd || true)"
if [ -z "$DATA" ]; then
    echo "[episode-audit] accountability-on-goblins/.data/ missing." >&2
    echo "Bootstrap it by running the accountability kernel first." >&2
    exit 1
fi
export GOBLINS_DATA_DIR="$DATA"
cd ../accountability-on-goblins/racket
exec racket audit.rkt "$@"
