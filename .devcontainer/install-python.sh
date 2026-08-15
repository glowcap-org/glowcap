#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"
pancake_require_devcontainer "install-python"

export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR}"

mkdir -p "${UV_PYTHON_INSTALL_DIR}"
bash "${dir}/install-uv.sh"
uv python install "${OCAPN_CONFORMANCE_PYTHON}" "${SERENA_PYTHON}"
chmod -R a+rX /usr/local/uv
