#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}" checksums
require_arch "zig"

cpu="$(linux_cpu)"
tarball="zig-${cpu}-linux-${ZIG_VERSION}.tar.xz"
url="https://ziglang.org/download/${ZIG_VERSION}/${tarball}"
tmp="$(mktemp -d -t pancake-zig-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

echo "downloading ${url}" >&2
curl --fail --location --silent --show-error --output "${tmp}/${tarball}" "${url}"
verify_download_sha256 "${tmp}/${tarball}" "$(zig_sha256)"

install_dir="/opt/zig"
mkdir -p "${install_dir}"
tar -xJf "${tmp}/${tarball}" --strip-components=1 -C "${install_dir}"
ln -sf "${install_dir}/zig" /usr/local/bin/zig
zig version
