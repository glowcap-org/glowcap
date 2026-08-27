#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_devcontainer_init "${dir}" checksums
pancake_require_devcontainer "image/rust"

# Image build uses CARGO_HOME_IMAGE; container open remaps to CARGO_HOME_RUNTIME
# (the cargo/ slice of the host bind).
export CARGO_HOME="${CARGO_HOME_IMAGE}"
export RUSTUP_HOME="${RUSTUP_HOME}"

# The pinned rustup-init bootstrap, not `curl | sh`: the toolchain below is
# verified by rustup against its signed manifest, and this closes the same
# loop on the installer itself.
triple="$(pancake_pick_by_arch rust x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu)"
url="https://static.rust-lang.org/rustup/archive/${RUSTUP_INIT_VERSION}/${triple}/rustup-init"
tmp="$(mktemp -d -t pancake-rust-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

pancake_fetch_verified "${url}" "${tmp}/rustup-init" "$(rustup_init_sha256)"
chmod +x "${tmp}/rustup-init"
"${tmp}/rustup-init" -y --no-modify-path --default-toolchain none --profile minimal

rustup toolchain install "${RUST_VERSION}" --profile minimal
rustup default "${RUST_VERSION}"
rustup component add rust-src rustfmt clippy

mkdir -p "${CARGO_HOME}/registry" "${CARGO_HOME}/git"
chmod -R a+rX "${RUSTUP_HOME}" "${CARGO_HOME}"

rustc --version
cargo --version
