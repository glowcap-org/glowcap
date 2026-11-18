#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}" checksums
glowcap_require_devcontainer "image/js-toolchains"

tmp="$(mktemp -d -t glowcap-js-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

deno_arch="$(glowcap_pick_by_arch deno x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu)"
node_arch="$(glowcap_pick_by_arch node linux-x64 linux-arm64)"
bun_arch="$(glowcap_pick_by_arch bun x64 aarch64)"

deno_zip="deno-${deno_arch}.zip"
deno_url="https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/${deno_zip}"
glowcap_fetch_verified "${deno_url}" "${tmp}/${deno_zip}" "$(deno_sha256)"
unzip -q "${tmp}/${deno_zip}" -d "${tmp}/deno"
install -d "${DENO_INSTALL}/bin"
install -m 0755 "${tmp}/deno/deno" "${DENO_INSTALL}/bin/deno"

node_tarball="node-v${NODE_VERSION}-${node_arch}.tar.xz"
node_url="https://nodejs.org/dist/v${NODE_VERSION}/${node_tarball}"
glowcap_fetch_verified "${node_url}" "${tmp}/${node_tarball}" "$(node_sha256)"
mkdir -p /opt/node
tar -xJf "${tmp}/${node_tarball}" --strip-components=1 -C /opt/node
ln -sf /opt/node/bin/node /usr/local/bin/node
ln -sf /opt/node/bin/npm /usr/local/bin/npm
ln -sf /opt/node/bin/npx /usr/local/bin/npx
npm install -g --no-fund --no-audit "npm@${NPM_VERSION}"

bun_zip="bun-linux-${bun_arch}.zip"
bun_url="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${bun_zip}"
glowcap_fetch_verified "${bun_url}" "${tmp}/${bun_zip}" "$(bun_sha256)"
unzip -q "${tmp}/${bun_zip}" -d "${tmp}/bun"
install -m 0755 "${tmp}/bun/bun-linux-${bun_arch}/bun" /usr/local/bin/bun

# Bend runs the browser Host import check on its JavaScript backend.
bend_arch="$(glowcap_pick_by_arch bend x64 arm64)"
bend_archive="bend-${BEND_VERSION}-linux-${bend_arch}.tar.gz"
bend_url="https://github.com/bendlang/bend/releases/download/v${BEND_VERSION}/${bend_archive}"
glowcap_fetch_verified "${bend_url}" "${tmp}/${bend_archive}" "$(bend_sha256)"
# The compiler finds its standard library relative to its executable.
mkdir -p /opt/bend
tar -xzf "${tmp}/${bend_archive}" --strip-components=1 -C /opt/bend
ln -sf /opt/bend/bin/bend /usr/local/bin/bend

bend version
deno --version
node --version
npm --version
bun --version
