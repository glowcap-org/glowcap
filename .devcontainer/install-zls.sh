#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}" checksums
require_arch "zls"

cpu="$(linux_cpu)"
tarball="zls-${cpu}-linux.tar.xz"
url="https://github.com/zigtools/zls/releases/download/${ZLS_VERSION}/${tarball}"
tmp="$(mktemp -d -t pancake-zls-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

echo "downloading ${url}" >&2
curl --fail --location --silent --show-error --output "${tmp}/${tarball}" "${url}"
verify_download_sha256 "${tmp}/${tarball}" "$(zls_sha256)"

tar -xJf "${tmp}/${tarball}" -C "${tmp}"
install -m 0755 "${tmp}/zls" /usr/local/bin/zls
zls --version
