#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}"
glowcap_require_devcontainer "image/rust-wasm"

export CARGO_HOME="${CARGO_HOME_IMAGE}"
version="$(python3 "${dir}/image/rooms-toolchain-version.py")"
rustup target add wasm32-unknown-unknown
cargo install wasm-bindgen-cli --version "${version}" --locked
wasm-bindgen --version
