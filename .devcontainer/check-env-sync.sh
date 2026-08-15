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
require_literal "${dockerfile}" "UV_TOOL_BIN_DIR=${UV_TOOL_BIN_DIR}" "Dockerfile UV_TOOL_BIN_DIR"
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
require_literal "${devcontainer_json}" '"workspaceFolder": "/workspaces/pancake"' "devcontainer.json workspace path"
if grep -Fq "\${localEnv:HOME}" "${devcontainer_json}"; then
    echo "devcontainer.json: host HOME mounts make contributor credentials ambient; use persistent named volumes" >&2
    exit 1
fi
while IFS=: read -r credential_volume credential_target; do
    require_literal "${compose_file}" "name: pancake-\${PANCAKE_WORKTREE:?Run bash .devcontainer/configure.sh}-${credential_volume}" "docker-compose.yml checkout-scoped credential volume"
    require_literal "${compose_file}" "target: ${credential_target}" "docker-compose.yml credential volume target"
    require_literal "${dir}/post-create.sh" "\"${credential_target}\"" "post-create.sh credential volume ownership"
done <<'EOF'
claude-home:/home/vscode/.claude
gh-config:/home/vscode/.config/gh
opencode-data:/home/vscode/.local/share/opencode
opencode-config:/home/vscode/.config/opencode
codex-home:/home/vscode/.codex
agent-resources:/home/vscode/.config/agents
EOF
require_literal "${compose_file}" "working_dir: /workspaces/pancake" "docker-compose.yml workspace path"
require_literal "${dir}/../.agents/skills/work/bin/pancake-dev" 'PANCAKE_DEV_WORKDIR:-/workspaces/pancake' "pancake-dev workspace path"
require_literal "${dir}/enter.sh" ".devcontainer/up.sh" "enter.sh delegates lifecycle to up.sh"
require_literal "${dir}/enter.sh" "tmux list-panes -s -t \"\${window_target}\"" "enter.sh qualifies list-panes with a session and window target"
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
require_literal "${compose_file}" "\${PANCAKE_WEB_HOST_PORT:?Run bash .devcontainer/configure.sh}:8000" "docker-compose.yml web host port"
require_literal "${compose_file}" "\${PANCAKE_CAPTP_HOST_PORT:?Run bash .devcontainer/configure.sh}:9099" "docker-compose.yml CapTP host port"
require_literal "${compose_file}" "\${PANCAKE_RELAY_HOST_PORT:?Run bash .devcontainer/configure.sh}:9200" "docker-compose.yml relay host port"
require_literal "${compose_file}" "\${PANCAKE_TRACE_HOST_PORT:?Run bash .devcontainer/configure.sh}:9300" "docker-compose.yml trace host port"

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
