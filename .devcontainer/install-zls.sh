#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}" checksums
pancake_require_devcontainer "install-zls"

cpu="$(pick_by_arch zls x86_64 aarch64)"
tarball="zls-${cpu}-linux.tar.xz"
url="https://github.com/zigtools/zls/releases/download/${ZLS_VERSION}/${tarball}"
tmp="$(mktemp -d -t pancake-zls-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

fetch_verified "${url}" "${tmp}/${tarball}" "$(zls_sha256)"

tar -xJf "${tmp}/${tarball}" -C "${tmp}"
install -m 0755 "${tmp}/zls" /usr/local/bin/zls
zls --version
