#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_devcontainer_init "${dir}" checksums
pancake_require_devcontainer "image/uv"

arch="$(pancake_pick_by_arch uv x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu)"
tarball="uv-${arch}.tar.gz"
url="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${tarball}"
tmp="$(mktemp -d -t pancake-uv-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

pancake_fetch_verified "${url}" "${tmp}/${tarball}" "$(uv_sha256)"

tar -xzf "${tmp}/${tarball}" -C "${tmp}"
install -m 0755 "${tmp}/uv-${arch}/uv" /usr/local/bin/uv
install -m 0755 "${tmp}/uv-${arch}/uvx" /usr/local/bin/uvx
uv --version
