#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}"
glowcap_require_devcontainer "image/codex"

npm install -g --no-fund --no-audit "@openai/codex@${CODEX_VERSION}"
ln -sf /opt/node/bin/codex /usr/local/bin/codex
codex --version
