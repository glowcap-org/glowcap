#!/usr/bin/env bash
# Cargo's native Linux linker, selected by .cargo/config.toml. Resolve LLD
# from the active Rust compiler so pin changes and both image architectures
# use the matching bundled linker. Preserve Cargo's arguments and exit status.
# test/build-front.sh exercises selection, quoting, and refusal.
set -euo pipefail

rust_lib=$("${RUSTC:-rustc}" --print target-libdir)
linker_dir="$(dirname "${rust_lib}")/bin/gcc-ld"
if [[ ! -x "${linker_dir}/ld.lld" ]]; then
    echo "rust-linker: active Rust toolchain has no bundled Linux LLD: ${linker_dir}" >&2
    exit 1
fi
exec cc "-B${linker_dir}" -fuse-ld=lld "$@"
