#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}" checksums
glowcap_require_devcontainer "image/opencode"

arch="$(glowcap_pick_by_arch opencode x64 arm64)"
tarball="opencode-linux-${arch}.tar.gz"
url="https://github.com/sst/opencode/releases/download/v${OPENCODE_VERSION}/${tarball}"
tmp="$(mktemp -d -t glowcap-opencode-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

glowcap_fetch_verified "${url}" "${tmp}/${tarball}" "$(opencode_sha256)"

tar -xzf "${tmp}/${tarball}" -C "${tmp}"
install -m 0755 "${tmp}/opencode" /usr/local/bin/opencode
opencode --version
