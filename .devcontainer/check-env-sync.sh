#!/usr/bin/env bash
# Fail if devcontainer pins, mounts, names, or host lifecycle contracts drift.
# Pure file and temporary-Git checks, so it runs anywhere: host or devcontainer.

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_source_pins "${dir}"

dockerfile="${dir}/Dockerfile"
devcontainer_json="${dir}/devcontainer.json"
compose_file="${dir}/docker-compose.yml"
env_example="${dir}/.env.example"

require_literal() {
    local file="$1"
    local needle="$2"
    local label="$3"
    if ! grep -Fq -- "${needle}" "${file}"; then
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
require_literal "${dockerfile}" "UV_TOOL_BIN_DIR=${UV_TOOL_BIN_DIR}" "Dockerfile UV_TOOL_BIN_DIR"
require_literal "${dockerfile}" "UV_PYTHON_INSTALL_DIR=${UV_PYTHON_INSTALL_DIR}" "Dockerfile UV_PYTHON_INSTALL_DIR"
require_literal "${dockerfile}" "PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH}" "Dockerfile PLAYWRIGHT_BROWSERS_PATH"
require_literal "${dockerfile}" "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR}" "Dockerfile CLAUDE_CONFIG_DIR"
require_literal "${dockerfile}" "CURSOR_CONFIG_DIR=${CURSOR_STATE_DIR}" "Dockerfile CURSOR_CONFIG_DIR"
require_literal "${dockerfile}" "CURSOR_DATA_DIR=${CURSOR_STATE_DIR}" "Dockerfile CURSOR_DATA_DIR"

require_literal "${devcontainer_json}" "\"CARGO_HOME\": \"${CARGO_HOME_RUNTIME}\"" "devcontainer.json CARGO_HOME (runtime)"
require_literal "${devcontainer_json}" "\"PLTUSERHOME\": \"${PLTUSERHOME}\"" "devcontainer.json PLTUSERHOME"
require_literal "${devcontainer_json}" "\"RUSTUP_HOME\": \"${RUSTUP_HOME}\"" "devcontainer.json RUSTUP_HOME"
require_literal "${devcontainer_json}" "\"DENO_DIR\": \"${DENO_DIR}\"" "devcontainer.json DENO_DIR"
require_literal "${devcontainer_json}" "\"BUN_INSTALL_CACHE_DIR\": \"${BUN_INSTALL_CACHE_DIR}\"" "devcontainer.json BUN_INSTALL_CACHE_DIR"
require_literal "${devcontainer_json}" "\"ZIG_GLOBAL_CACHE_DIR\": \"${ZIG_CACHE_DIR}\"" "devcontainer.json ZIG_GLOBAL_CACHE_DIR"
require_literal "${devcontainer_json}" "\"npm_config_cache\": \"${NPM_CACHE_DIR}\"" "devcontainer.json npm_config_cache"
require_literal "${devcontainer_json}" "\"PIP_CACHE_DIR\": \"${PIP_CACHE_DIR}\"" "devcontainer.json PIP_CACHE_DIR"
require_literal "${devcontainer_json}" "\"PLAYWRIGHT_BROWSERS_PATH\": \"${PLAYWRIGHT_BROWSERS_PATH}\"" "devcontainer.json PLAYWRIGHT_BROWSERS_PATH"
require_literal "${devcontainer_json}" "\"CLAUDE_CONFIG_DIR\": \"${CLAUDE_CONFIG_DIR}\"" "devcontainer.json CLAUDE_CONFIG_DIR"
require_literal "${devcontainer_json}" "\"CURSOR_CONFIG_DIR\": \"${CURSOR_STATE_DIR}\"" "devcontainer.json CURSOR_CONFIG_DIR"
require_literal "${devcontainer_json}" "\"CURSOR_DATA_DIR\": \"${CURSOR_STATE_DIR}\"" "devcontainer.json CURSOR_DATA_DIR"

require_literal "${dockerfile}" "npm_config_cache=${NPM_CACHE_DIR}" "Dockerfile npm_config_cache"
require_literal "${dockerfile}" "PIP_CACHE_DIR=${PIP_CACHE_DIR}" "Dockerfile PIP_CACHE_DIR"
require_literal "${devcontainer_json}" "target=${CARGO_HOME_RUNTIME},type=volume" "devcontainer.json cargo volume"
require_literal "${devcontainer_json}" '"workspaceFolder": "/workspaces/pancake"' "devcontainer.json workspace path"
require_literal "${dir}/initialize.sh" 'pancake_devcontainer_host_state_rows' "initialize.sh shared host-state inventory"
require_literal "${dir}/post-create.sh" 'pancake_devcontainer_host_state_rows' "post-create.sh shared host-state inventory"
expected_host_mounts=0
owned_dir_block="$(sed -n '/^persistent_dirs=(/,/^)/p' "${dir}/post-create.sh")"
while IFS=: read -r host_relative host_target; do
    expected_host_mounts=$((expected_host_mounts + 1))
    require_literal "${devcontainer_json}" "source=\${localEnv:HOME}/${host_relative},target=${host_target},type=bind" "devcontainer.json shared host-state mount"
    if grep -Fq "target: ${host_target}" "${compose_file}"; then
        echo "docker-compose.yml: ${host_target} must come from the shared host bind in devcontainer.json" >&2
        exit 1
    fi
    if grep -Fq "${host_target}" <<< "${owned_dir_block}"; then
        echo "post-create.sh: shared host path must not be recursively owned by the container: ${host_target}" >&2
        exit 1
    fi
done <<< "$(pancake_devcontainer_host_state_rows)"
actual_host_mounts="$(grep -Fc "source=\${localEnv:HOME}/" "${devcontainer_json}")"
if [[ "${actual_host_mounts}" -ne "${expected_host_mounts}" ]]; then
    echo "devcontainer.json: every host-home mount must be declared by pancake_devcontainer_host_state_rows" >&2
    exit 1
fi

# Two of the agent CLIs pick their state directory from the environment rather
# than writing to a fixed path, so a mount alone does not share their settings
# and the variable alone does not reach the host. The rows above name every path
# the host reaches; each variable has to land on one of them. Setting either
# side without the other looks tidy and still forgets state on the next
# rebuild, which is how Claude Code came to keep ~/.claude.json in the
# container's own writable layer beside a mounted ~/.claude. The Cursor agent
# CLI's Linux token file does not follow CURSOR_CONFIG_DIR, so that directory
# is required here on its own.
require_shared_target() {
    local label="$1" wanted="$2" host_target
    while IFS=: read -r _ host_target; do
        [[ "${host_target}" == "${wanted}" ]] && return 0
    done <<< "$(pancake_devcontainer_host_state_rows)"
    echo "${label}=${wanted} is not a shared host-state mount target" >&2
    return 1
}
require_shared_target CLAUDE_CONFIG_DIR "${CLAUDE_CONFIG_DIR}"
require_shared_target CURSOR_CONFIG_DIR "${CURSOR_STATE_DIR}"
require_shared_target CURSOR_DATA_DIR "${CURSOR_STATE_DIR}"
require_shared_target CURSOR_AUTH_DIR "${CURSOR_AUTH_DIR}"
require_literal "${dockerfile}" "${CURSOR_AUTH_DIR}" "Dockerfile Cursor Linux auth directory"

require_literal "${compose_file}" "working_dir: /workspaces/pancake" "docker-compose.yml workspace path"
require_literal "${dir}/../.agents/skills/work/bin/pancake-dev" 'PANCAKE_DEV_WORKDIR:-/workspaces/pancake' "pancake-dev workspace path"
require_literal "${dir}/launcher-lib.sh" ".devcontainer/up.sh" "launchers delegate lifecycle to up.sh"
require_literal "${dir}/launcher-lib.sh" "tmux list-panes -s -t \"\${window_target}\"" "the dead-session sweep qualifies list-panes with a session and window target"
require_literal "${dir}/launcher-lib.sh" "--rcfile .devcontainer/pane-rc.sh" "pane shells start through pane-rc.sh"
require_literal "${dir}/enter-grid.sh" "-P -F '#{pane_id}'" "enter-grid.sh addresses grid panes by pane id"
require_literal "${dir}/enter-grid.sh" "panes_names[i]=panes.sh" "enter-grid.sh names the panes.sh contract pane-rc.sh defaults to"
require_literal "${dir}/pane-rc.sh" '[[ -f ~/.bashrc ]] && source ~/.bashrc' "pane-rc.sh initializes the interactive shell before the startup command"
require_literal "${dir}/pane-rc.sh" 'PANCAKE_GRID_PANES:-panes.sh' "pane-rc.sh defaults to the panes.sh contract"
require_literal "${compose_file}" "container_name: pancake-\${PANCAKE_WORKTREE:?Run bash .devcontainer/configure.sh}" "docker-compose.yml worktree container name"
require_literal "${compose_file}" "image: vsc-pancake-\${PANCAKE_WORKTREE:?Run bash .devcontainer/configure.sh}" "docker-compose.yml worktree image name"
require_literal "${compose_file}" "PANCAKE_WORKTREE: \${PANCAKE_WORKTREE:?Run bash .devcontainer/configure.sh}" "docker-compose.yml worktree environment"
require_literal "${env_example}" "PANCAKE_WORKTREE=main" ".env.example primary worktree default"
while IFS=: read -r port_variable port_default; do
    require_literal "${env_example}" "${port_variable}=${port_default}" ".env.example primary host port"
done <<< "$(pancake_devcontainer_port_rows)"
require_literal "${env_example}" "EGRESS_NET=$(pancake_devcontainer_default_egress_network main)" ".env.example primary egress network"
require_literal "${compose_file}" "source: \${PANCAKE_GIT_COMMON_DIR:?" "docker-compose.yml Git common-dir source"
require_literal "${compose_file}" "target: \${PANCAKE_GIT_COMMON_DIR:?" "docker-compose.yml Git common-dir target"
require_literal "${env_example}" "PANCAKE_GIT_COMMON_DIR=" ".env.example Git common directory"
require_literal "${dir}/initialize.sh" "bash \"\${dir}/configure.sh\"" "initialize.sh bootstraps the checkout environment"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_ROOMS_WEB_HOST_PORT:?Run bash .devcontainer/configure.sh}:8000" "docker-compose.yml web host port"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_ROOMS_CAPTP_HOST_PORT:?Run bash .devcontainer/configure.sh}:9099" "docker-compose.yml CapTP host port"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_ROOMS_RELAY_HOST_PORT:?Run bash .devcontainer/configure.sh}:9200" "docker-compose.yml relay host port"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_ROOMS_TRACE_HOST_PORT:?Run bash .devcontainer/configure.sh}:9300" "docker-compose.yml trace host port"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_OCAPNVIZ_HOST_PORT:?Run bash .devcontainer/configure.sh}:5173" "docker-compose.yml ocapnviz host port"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_DOCS_HOST_PORT:?Run bash .devcontainer/configure.sh}:1990" "docker-compose.yml docs-serve host port"
require_literal "${compose_file}" "OCAPNVIZ_HOST: 0.0.0.0" "docker-compose.yml ocapnviz Vite bind"
require_literal "${compose_file}" "DOCS_SERVE_HOST: 0.0.0.0" "docker-compose.yml docs-serve bind"
require_literal "${dir}/../apps/ocapnviz/vite-dev-listen.ts" "allowedHosts: true" "ocapnviz Vite Host-header policy for a wide bind"
require_literal "${dir}/../site/docs-serve.sh" 'DOCS_SERVE_HOST:-127.0.0.1' "docs-serve.sh forwards the container-wide bind"

# Every mount target under the container's home must have its parents created,
# owned by vscode, in the image. Docker creates a missing mount path as root,
# and it creates missing parents the same way. That is invisible until someone
# opens a fresh container, which is the worst place to find it.
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
$(sed -n "s|^ *target: \(${home_dir}[^ ]*\) *$|\1|p" "${compose_file}")
EOF

bash "${dir}/test-host-invariants.sh"
