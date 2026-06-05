#!/usr/bin/env bash
# Idempotently initialize the conformance upstream submodules:
#   - ocapn-conformance/upstream  (the OCapN test suite)
#   - ocapn-spec/upstream         (OCapN spec, for citations)
#   - syrup/upstream              (Syrup spec, for citations)
#   - spritely-goblins/upstream   (Goblins source, for wire-shape lookup)
# Safe to re-run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
git submodule update --init --recursive \
    conformance/ocapn-conformance/upstream \
    conformance/ocapn-spec/upstream \
    conformance/syrup/upstream \
    conformance/spritely-goblins/upstream
echo "conformance submodules initialized."
