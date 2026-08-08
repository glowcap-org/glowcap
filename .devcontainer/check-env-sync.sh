#!/usr/bin/env bash
# Fail if pins.sh paths diverge from Dockerfile ENV and devcontainer.json.

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_source_pins "${dir}"

dockerfile="${dir}/Dockerfile"
devcontainer_json="${dir}/devcontainer.json"

require_literal() {
    local file="$1"
    local needle="$2"
    local label="$3"
    if ! grep -Fq "${needle}" "${file}"; then
        echo "${label}: expected literal '${needle}' in ${file}" >&2
        return 1
    fi
}

require_literal "${dockerfile}" "CARGO_HOME=${CARGO_HOME_IMAGE}" "Dockerfile CARGO_HOME (image build)"
require_literal "${dockerfile}" "PLTUSERHOME=${PLTUSERHOME}" "Dockerfile PLTUSERHOME"
require_literal "${dockerfile}" "RUSTUP_HOME=${RUSTUP_HOME}" "Dockerfile RUSTUP_HOME"
require_literal "${dockerfile}" "DENO_DIR=${DENO_DIR}" "Dockerfile DENO_DIR"
require_literal "${dockerfile}" "DENO_INSTALL=${DENO_INSTALL}" "Dockerfile DENO_INSTALL"
require_literal "${dockerfile}" "BUN_INSTALL_CACHE_DIR=${BUN_INSTALL_CACHE_DIR}" "Dockerfile BUN_INSTALL_CACHE_DIR"
require_literal "${dockerfile}" "ZIG_GLOBAL_CACHE_DIR=${ZIG_CACHE_DIR}" "Dockerfile ZIG_GLOBAL_CACHE_DIR"
require_literal "${dockerfile}" "UV_TOOL_DIR=${UV_TOOL_DIR}" "Dockerfile UV_TOOL_DIR"
require_literal "${dockerfile}" "UV_PYTHON_INSTALL_DIR=${UV_PYTHON_INSTALL_DIR}" "Dockerfile UV_PYTHON_INSTALL_DIR"
require_literal "${dockerfile}" "PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH}" "Dockerfile PLAYWRIGHT_BROWSERS_PATH"

require_literal "${devcontainer_json}" "\"CARGO_HOME\": \"${CARGO_HOME_RUNTIME}\"" "devcontainer.json CARGO_HOME (runtime)"
require_literal "${devcontainer_json}" "\"PLTUSERHOME\": \"${PLTUSERHOME}\"" "devcontainer.json PLTUSERHOME"
require_literal "${devcontainer_json}" "\"RUSTUP_HOME\": \"${RUSTUP_HOME}\"" "devcontainer.json RUSTUP_HOME"
require_literal "${devcontainer_json}" "\"DENO_DIR\": \"${DENO_DIR}\"" "devcontainer.json DENO_DIR"
require_literal "${devcontainer_json}" "\"BUN_INSTALL_CACHE_DIR\": \"${BUN_INSTALL_CACHE_DIR}\"" "devcontainer.json BUN_INSTALL_CACHE_DIR"
require_literal "${devcontainer_json}" "\"ZIG_GLOBAL_CACHE_DIR\": \"${ZIG_CACHE_DIR}\"" "devcontainer.json ZIG_GLOBAL_CACHE_DIR"
require_literal "${devcontainer_json}" "\"npm_config_cache\": \"${NPM_CACHE_DIR}\"" "devcontainer.json npm_config_cache"
require_literal "${devcontainer_json}" "\"PIP_CACHE_DIR\": \"${PIP_CACHE_DIR}\"" "devcontainer.json PIP_CACHE_DIR"
require_literal "${devcontainer_json}" "\"PLAYWRIGHT_BROWSERS_PATH\": \"${PLAYWRIGHT_BROWSERS_PATH}\"" "devcontainer.json PLAYWRIGHT_BROWSERS_PATH"

require_literal "${dockerfile}" "npm_config_cache=${NPM_CACHE_DIR}" "Dockerfile npm_config_cache"
require_literal "${dockerfile}" "PIP_CACHE_DIR=${PIP_CACHE_DIR}" "Dockerfile PIP_CACHE_DIR"
require_literal "${devcontainer_json}" "target=${CARGO_HOME_RUNTIME},type=volume" "devcontainer.json cargo volume"

# Every mount target under the container's home must have its parents created,
# owned by vscode, in the image. Docker creates a missing mount path as root,
# and it creates the missing *parents* the same way — so a bind two levels deep
# into a directory the image never made leaves that directory root-owned, and
# the first tool that writes beside it fails with EACCES. That is invisible
# until someone opens a fresh container, which is the worst place to find it.
#
# The check reads the mount targets out of devcontainer.json and asserts the
# Dockerfile's user-space `mkdir -p` covers each one's parent directory.
home_dir="/home/vscode"
mkdir_targets="$(sed -n 's|^ *&& *mkdir -p \(.*\) *\\$|\1|p; s|^ *\('"${home_dir}"'/[^ ]*\) *\\$|\1|p' "${dockerfile}")"

covered() {
    local needed="$1" made
    for made in ${mkdir_targets}; do
        case "${needed}" in
            "${made}" | "${made}"/*) return 0 ;;
        esac
    done
    return 1
}

while read -r target; do
    [ -n "${target}" ] || continue
    parent="$(dirname "${target}")"
    # A direct child of home needs nothing: the image creates home itself.
    [ "${parent}" != "${home_dir}" ] || continue
    if ! covered "${parent}"; then
        echo "devcontainer.json mounts ${target}, but ${dockerfile} never creates ${parent}." >&2
        echo "  Docker would create it as root and the container's own user could not write beside it." >&2
        echo "  Add ${parent} to the vscode user-space 'mkdir -p' in the Dockerfile." >&2
        exit 1
    fi
done <<EOF
$(sed -n "s|.*target=\(${home_dir}[^,]*\),.*|\1|p" "${devcontainer_json}")
EOF
