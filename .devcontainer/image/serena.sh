#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_devcontainer_init "${dir}"
pancake_require_devcontainer "image/serena"

export UV_TOOL_DIR="${UV_TOOL_DIR}"
export UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR}"

mkdir -p "${UV_TOOL_DIR}" "${UV_PYTHON_INSTALL_DIR}"
uv tool install -p "${SERENA_PYTHON}" "serena-agent==${SERENA_AGENT_VERSION}"
chmod -R a+rX /usr/local/uv
serena --version
