#!/usr/bin/env bash
# Native entry point. Runs the keripy oracle via `uv` (devcontainer
# provides uv/python) — no pixi/conda env. Verifies the KERI outputs under
# the sibling accountability-on-goblins/.data/ (or a pinned fixture via
# --fixture <name>, e.g. sample-kel).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

FIXTURE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fixture)
            shift
            [ $# -gt 0 ] || { echo "run.sh: --fixture requires a name (e.g. sample-kel)" >&2; exit 2; }
            FIXTURE="$1"; shift ;;
        *) break ;;
    esac
done

if [ -n "$FIXTURE" ]; then
    DATA_DIR="$(pwd)/fixtures/$FIXTURE"
    [ -d "$DATA_DIR" ] || { echo "run.sh: unknown fixture '$FIXTURE' (no $DATA_DIR)" >&2; exit 2; }
else
    DATA_DIR="$(cd ../accountability-on-goblins/.data 2>/dev/null && pwd || true)"
    [ -n "$DATA_DIR" ] || { echo "run.sh: accountability-on-goblins/.data missing; pass --fixture sample-kel" >&2; exit 1; }
fi
export GOBLINS_DATA_DIR="$DATA_DIR"

DEPS=(--python 3.12 --with 'pynacl>=1.5.0' --with 'blake3>=0.4.0' --with 'keri==1.2.6')
exec uv run "${DEPS[@]}" python oracle/verify.py "$@"
