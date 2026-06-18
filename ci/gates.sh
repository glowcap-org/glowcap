#!/usr/bin/env bash
# The full gate sequence, forge-neutral. CI wrappers (.forgejo/workflows/,
# .github/workflows/) run this inside the committed devcontainer image — the
# same commands a contributor runs. The project gate itself stays
# `zig build check`; this script only sequences it with the cross-language
# sibling gates that need the non-Zig runtimes the image carries.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

bash .devcontainer/post-create.sh

zig build check
zig build bindings-fmt-check
zig build rust-dogfood
zig build bindings
zig build goblins-interop
zig build goblins-handoff
zig build fixture-gen-check
zig build ocapn-conformance
zig build iroh-interop
