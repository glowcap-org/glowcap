#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}"
glowcap_require_devcontainer "image/uv-tools"

export UV_TOOL_DIR="${UV_TOOL_DIR}"
export UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR}"

mkdir -p "${UV_TOOL_DIR}" "${UV_PYTHON_INSTALL_DIR}"
# The Python tools the image owns, each a pinned uv tool on the pinned
# Python: Serena for the coding agents, ruff for `python-check`, and mypy
# for every Python type check.
uv tool install -p "${PYTHON_VERSION}" "serena-agent==${SERENA_AGENT_VERSION}"
uv tool install -p "${PYTHON_VERSION}" "ruff==${RUFF_VERSION}"
uv tool install -p "${PYTHON_VERSION}" "mypy==${MYPY_VERSION}"
chmod -R a+rX /usr/local/uv
serena --version
ruff --version
mypy --version
