#!/usr/bin/env bash
# Native entry point. Racket + Spritely Goblins come from the devcontainer
# (.devcontainer/install-racket-goblins.sh) and are on PATH.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/racket"
case "${1:-seven-caps-peer}" in
    seven-caps-peer) exec racket seven-caps-peer.rkt ;;
    smoke) exec bash smoke.sh ;;
    run) shift; exec racket "$@" ;;
    shell) exec bash ;;
    *) echo "usage: run.sh [seven-caps-peer|smoke|run <script.rkt>|shell]" >&2; exit 2 ;;
esac
