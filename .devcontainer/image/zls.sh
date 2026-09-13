#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}" checksums
glowcap_require_devcontainer "image/zls"

tarball="zls-${ZLS_SOURCE_REVISION}.tar.gz"
url="https://github.com/zigtools/zls/archive/${ZLS_SOURCE_REVISION}.tar.gz"
tmp="$(mktemp -d -t glowcap-zls-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

glowcap_fetch_verified "${url}" "${tmp}/${tarball}" "${ZLS_SOURCE_SHA256}"

tar -xzf "${tmp}/${tarball}" --strip-components=1 -C "${tmp}"
(
    cd "${tmp}"
    zig build -Doptimize=ReleaseSafe -Dversion-string="${ZLS_VERSION}"
)
install -m 0755 "${tmp}/zig-out/bin/zls" /usr/local/bin/zls
zls --version
