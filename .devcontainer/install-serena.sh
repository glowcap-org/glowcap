#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"

export UV_TOOL_DIR="${UV_TOOL_DIR}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR}"

mkdir -p "${UV_TOOL_DIR}" "${UV_PYTHON_INSTALL_DIR}"
bash "${dir}/install-uv.sh"
uv tool install -p "${SERENA_PYTHON}" "serena-agent==${SERENA_AGENT_VERSION}"
chmod -R a+rX /usr/local/uv
serena --version
