#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}" checksums
require_arch "javascript toolchains"

tmp="$(mktemp -d -t pancake-js-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

case "$(uname -m)" in
    x86_64)
        deno_arch="x86_64-unknown-linux-gnu"
        node_arch="linux-x64"
        bun_arch="x64"
        ;;
    aarch64)
        deno_arch="aarch64-unknown-linux-gnu"
        node_arch="linux-arm64"
        bun_arch="aarch64"
        ;;
esac

deno_zip="deno-${deno_arch}.zip"
deno_url="https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/${deno_zip}"
echo "downloading ${deno_url}" >&2
curl --fail --location --silent --show-error --output "${tmp}/${deno_zip}" "${deno_url}"
verify_download_sha256 "${tmp}/${deno_zip}" "$(deno_sha256)"
unzip -q "${tmp}/${deno_zip}" -d "${tmp}/deno"
install -d "${DENO_INSTALL}/bin"
install -m 0755 "${tmp}/deno/deno" "${DENO_INSTALL}/bin/deno"

node_tarball="node-v${NODE_VERSION}-${node_arch}.tar.xz"
node_url="https://nodejs.org/dist/v${NODE_VERSION}/${node_tarball}"
echo "downloading ${node_url}" >&2
curl --fail --location --silent --show-error --output "${tmp}/${node_tarball}" "${node_url}"
verify_download_sha256 "${tmp}/${node_tarball}" "$(node_sha256)"
mkdir -p /opt/node
tar -xJf "${tmp}/${node_tarball}" --strip-components=1 -C /opt/node
ln -sf /opt/node/bin/node /usr/local/bin/node
ln -sf /opt/node/bin/npm /usr/local/bin/npm
ln -sf /opt/node/bin/npx /usr/local/bin/npx

bun_zip="bun-linux-${bun_arch}.zip"
bun_url="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${bun_zip}"
echo "downloading ${bun_url}" >&2
curl --fail --location --silent --show-error --output "${tmp}/${bun_zip}" "${bun_url}"
verify_download_sha256 "${tmp}/${bun_zip}" "$(bun_sha256)"
unzip -q "${tmp}/${bun_zip}" -d "${tmp}/bun"
install -m 0755 "${tmp}/bun/bun-linux-${bun_arch}/bun" /usr/local/bin/bun

deno --version
node --version
npm --version
bun --version
