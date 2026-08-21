#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_devcontainer_init "${dir}"
pancake_require_devcontainer "image/python"

export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR}"

mkdir -p "${UV_PYTHON_INSTALL_DIR}"
bash "${dir}/image/uv.sh"
uv python install "${OCAPN_CONFORMANCE_PYTHON}" "${SERENA_PYTHON}"
chmod -R a+rX /usr/local/uv
