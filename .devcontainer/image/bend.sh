#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}" checksums
glowcap_require_devcontainer "image/bend"

arch="$(glowcap_pick_by_arch bend x64 arm64)"
archive="bend-${BEND_VERSION}-linux-${arch}.tar.gz"
url="https://github.com/bendlang/bend/releases/download/v${BEND_VERSION}/${archive}"
tmp="$(mktemp -d -t glowcap-bend-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

glowcap_fetch_verified "${url}" "${tmp}/${archive}" "$(bend_sha256)"
# Bend resolves its standard library relative to the executable.
mkdir -p /opt/bend
tar -xzf "${tmp}/${archive}" --strip-components=1 -C /opt/bend
ln -sf /opt/bend/bin/bend /usr/local/bin/bend
bend version
