#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_devcontainer_init "${dir}" checksums
pancake_require_devcontainer "image/opencode"

arch="$(pancake_pick_by_arch opencode x64 arm64)"
tarball="opencode-linux-${arch}.tar.gz"
url="https://github.com/sst/opencode/releases/download/v${OPENCODE_VERSION}/${tarball}"
tmp="$(mktemp -d -t pancake-opencode-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

pancake_fetch_verified "${url}" "${tmp}/${tarball}" "$(opencode_sha256)"

tar -xzf "${tmp}/${tarball}" -C "${tmp}"
install -m 0755 "${tmp}/opencode" /usr/local/bin/opencode
opencode --version
