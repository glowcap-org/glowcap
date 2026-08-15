#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"
pancake_require_devcontainer "install-codex"

npm install -g --no-fund --no-audit "@openai/codex@${CODEX_VERSION}"
ln -sf /opt/node/bin/codex /usr/local/bin/codex
codex --version
