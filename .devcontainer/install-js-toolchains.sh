#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}" checksums
pancake_require_devcontainer "install-js-toolchains"

tmp="$(mktemp -d -t pancake-js-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

deno_arch="$(pick_by_arch deno x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu)"
node_arch="$(pick_by_arch node linux-x64 linux-arm64)"
bun_arch="$(pick_by_arch bun x64 aarch64)"

deno_zip="deno-${deno_arch}.zip"
deno_url="https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/${deno_zip}"
fetch_verified "${deno_url}" "${tmp}/${deno_zip}" "$(deno_sha256)"
unzip -q "${tmp}/${deno_zip}" -d "${tmp}/deno"
install -d "${DENO_INSTALL}/bin"
install -m 0755 "${tmp}/deno/deno" "${DENO_INSTALL}/bin/deno"

node_tarball="node-v${NODE_VERSION}-${node_arch}.tar.xz"
node_url="https://nodejs.org/dist/v${NODE_VERSION}/${node_tarball}"
fetch_verified "${node_url}" "${tmp}/${node_tarball}" "$(node_sha256)"
mkdir -p /opt/node
tar -xJf "${tmp}/${node_tarball}" --strip-components=1 -C /opt/node
ln -sf /opt/node/bin/node /usr/local/bin/node
ln -sf /opt/node/bin/npm /usr/local/bin/npm
ln -sf /opt/node/bin/npx /usr/local/bin/npx

bun_zip="bun-linux-${bun_arch}.zip"
bun_url="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${bun_zip}"
fetch_verified "${bun_url}" "${tmp}/${bun_zip}" "$(bun_sha256)"
unzip -q "${tmp}/${bun_zip}" -d "${tmp}/bun"
install -m 0755 "${tmp}/bun/bun-linux-${bun_arch}/bun" /usr/local/bin/bun

deno --version
node --version
npm --version
bun --version
