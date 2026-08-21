#!/usr/bin/env bash
# Cursor's agent CLI. Upstream's cursor.com/install script unpacks a dated
# build under ~/.local/share and links it into ~/.local/bin; this installs the
# same package to a shared system path so the pinned build belongs to the image
# and no per-user state carries the binary. Both upstream command names are
# linked: `agent` is the current one, `cursor-agent` the original.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_devcontainer_init "${dir}" checksums
pancake_require_devcontainer "image/cursor-agent"

arch="$(pancake_pick_by_arch cursor-agent x64 arm64)"
tarball="agent-cli-package.tar.gz"
url="https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/${arch}/${tarball}"
target="${CURSOR_AGENT_DIR}/${CURSOR_AGENT_VERSION}"
tmp="$(mktemp -d -t pancake-cursor-agent-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

pancake_fetch_verified "${url}" "${tmp}/${tarball}" "$(cursor_agent_sha256)"

# The package's launcher resolves its bundled node and helper binaries relative
# to its own realpath, so the whole directory moves together and a symlink from
# PATH still finds them.
mkdir -p "${target}"
tar --strip-components=1 -xzf "${tmp}/${tarball}" -C "${target}"
ln -sf "${target}/cursor-agent" /usr/local/bin/agent
ln -sf "${target}/cursor-agent" /usr/local/bin/cursor-agent
# Even `--version` writes a default settings file into the configured state
# directory, and this runs as root while that directory is the vscode user's
# bind-mount target. Point it at the scratch directory instead, so the image
# never carries a root-owned stub where the host's login is about to land.
CURSOR_CONFIG_DIR="${tmp}/state" CURSOR_DATA_DIR="${tmp}/state" cursor-agent --version
