#!/usr/bin/env bash
# The one checksummed Zig install: the devcontainer image build and every CI
# job (the checks sequence, the release legs) installs the pinned
# compiler through this script, so the version and SHA-256 authority stays in
# pins.sh + checksums.sh. ZIG_INSTALL_DIR overrides the /opt/zig prefix for
# runners without root; the /usr/local/bin symlink is laid only for the
# default prefix. Alone among the installers this one runs anywhere — the
# release workflow uses it on macOS runners — so it carries no devcontainer
# guard and stays portable to macOS (bash 3.2, shasum, bsdtar).
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_devcontainer_init "${dir}" checksums

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) triple="x86_64-linux" ;;
    Linux-aarch64) triple="aarch64-linux" ;;
    Darwin-arm64) triple="aarch64-macos" ;;
    Darwin-x86_64) triple="x86_64-macos" ;;
    *)
        echo "image/zig: unsupported platform: $(uname -s)-$(uname -m)" >&2
        exit 1
        ;;
esac

tarball="zig-${triple}-${ZIG_VERSION}.tar.xz"
if [[ "${ZIG_VERSION}" == *-dev.* ]]; then
    url="https://ziglang.org/builds/${tarball}"
else
    url="https://ziglang.org/download/${ZIG_VERSION}/${tarball}"
fi
tmp="$(mktemp -d -t pancake-zig-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

pancake_fetch_verified "${url}" "${tmp}/${tarball}" "$(zig_sha256)"

install_dir="${ZIG_INSTALL_DIR:-/opt/zig}"
mkdir -p "${install_dir}"
tar -xJf "${tmp}/${tarball}" --strip-components=1 -C "${install_dir}"
if [[ -z "${ZIG_INSTALL_DIR:-}" ]]; then
    ln -sf "${install_dir}/zig" /usr/local/bin/zig
fi
"${install_dir}/zig" version
