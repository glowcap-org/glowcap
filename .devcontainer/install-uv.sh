#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}" checksums
require_arch "uv"

case "$(uname -m)" in
    x86_64) arch="x86_64-unknown-linux-gnu" ;;
    aarch64) arch="aarch64-unknown-linux-gnu" ;;
esac

tarball="uv-${arch}.tar.gz"
url="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${tarball}"
tmp="$(mktemp -d -t pancake-uv-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

echo "downloading ${url}" >&2
curl --fail --location --silent --show-error --output "${tmp}/${tarball}" "${url}"
verify_download_sha256 "${tmp}/${tarball}" "$(uv_sha256)"

tar -xzf "${tmp}/${tarball}" -C "${tmp}"
install -m 0755 "${tmp}/uv-${arch}/uv" /usr/local/bin/uv
install -m 0755 "${tmp}/uv-${arch}/uvx" /usr/local/bin/uvx
uv --version
