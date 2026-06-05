#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"

# Image build uses CARGO_HOME_IMAGE; container open remaps to CARGO_HOME_RUNTIME (volume).
export CARGO_HOME="${CARGO_HOME_IMAGE}"
export RUSTUP_HOME="${RUSTUP_HOME}"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --default-toolchain none --profile minimal

rustup toolchain install "${RUST_VERSION}" --profile minimal
rustup default "${RUST_VERSION}"
rustup component add rust-src rustfmt clippy

mkdir -p "${CARGO_HOME}/registry" "${CARGO_HOME}/git"
chmod -R a+rX "${RUSTUP_HOME}" "${CARGO_HOME}"

rustc --version
cargo --version
