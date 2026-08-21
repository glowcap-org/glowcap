#!/usr/bin/env bash
# Fail if devcontainer pins, mounts, names, structure, or host lifecycle
# contracts drift. Pure file checks, so it runs anywhere, host or container.
# Its sibling test/host-invariants.sh covers behaviour; `zig build
# source-check` runs both.

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
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
require_literal "${dir}/hooks/initialize.sh" 'pancake_devcontainer_host_state_rows' "hooks/initialize.sh shared host-state inventory"
require_literal "${dir}/hooks/post-create.sh" 'pancake_devcontainer_host_state_rows' "hooks/post-create.sh shared host-state inventory"
expected_host_mounts=0
owned_dir_block="$(sed -n '/^persistent_dirs=(/,/^)/p' "${dir}/hooks/post-create.sh")"
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
require_literal "${dir}/lib/launcher.sh" "tmux list-panes -s -t \"\${window_target}\"" "the dead-session sweep qualifies list-panes with a session and window target"
require_literal "${dir}/lib/launcher.sh" "pane/host/.bashrc" "pane shells start through the host half of the pane runtime"
require_literal "${dir}/bin/enter-grid.sh" "-P -F '#{pane_id}'" "enter-grid.sh addresses grid panes by pane id"
require_literal "${dir}/hooks/post-create.sh" "find \"\${dir}\" -name '*.sh'" "the lint reaches every shell file in the tree, not only the top of it"
require_literal "${dir}/hooks/post-create.sh" "conformance/bootstrap-submodules.sh" "post-create fills the conformance submodules so every worktree is a complete checkout"
require_literal "${dir}/lib/launcher.sh" "panes_name=panes.sh" "the launchers name the panes.sh contract the runtime defaults to"
require_literal "${dir}/bin/container-id.sh" "pancake_devcontainer_checkout_entry" "the container lookup finds that checkout's own up.sh"
require_literal "${dir}/bin/container-id.sh" "bash \"\${lifecycle}\"" "the container lookup runs the lifecycle it found"
require_literal "${dir}/lib/launcher.sh" "pancake_devcontainer_checkout_entry" "launchers accept a checkout whose up.sh has not moved into bin/"
require_literal "${dir}/pane/host/.bashrc" ".devcontainer/pane/container" "the host half of the runtime opens the container half"
require_literal "${dir}/pane/host/.bashrc" '[[ -f ~/.bashrc ]] && source ~/.bashrc' "the host pane shell is initialized before it enters the container"
require_literal "${dir}/pane/host/.bashrc" "PANCAKE_TMUX_DETACH_STATUS=" "the host half declares the status that leaves the container and keeps the pane"
require_literal "${dir}/pane/host/.bashrc" "PANCAKE_TMUX_PANES_NAME:-panes.sh" "the host half defaults to the panes.sh contract"
require_literal "${dir}/pane/container/.zshrc" '[[ -f ~/.zshrc ]] && source ~/.zshrc' "the container pane shell is initialized before the startup command"
require_literal "${dir}/pane/container/.zshrc" "PANCAKE_TMUX_PANES_FILE" "the container half reads the panes file the host half named"
require_literal "${dir}/pane/container/.zshrc" "../host/.bashrc" "the container half names the host half it answers to"
require_literal "${dir}/pane/container/.zshrc" "PANCAKE_TMUX_DETACH_STATUS" "the container half exits with the status the host half declared"
require_literal "${compose_file}" "container_name: pancake-\${PANCAKE_WORKTREE:?Run bash .devcontainer/bin/configure.sh}" "docker-compose.yml worktree container name"
require_literal "${compose_file}" "image: vsc-pancake-\${PANCAKE_WORKTREE:?Run bash .devcontainer/bin/configure.sh}" "docker-compose.yml worktree image name"
require_literal "${compose_file}" "PANCAKE_WORKTREE: \${PANCAKE_WORKTREE:?Run bash .devcontainer/bin/configure.sh}" "docker-compose.yml worktree environment"
require_literal "${env_example}" "PANCAKE_WORKTREE=main" ".env.example primary worktree default"
while IFS=: read -r port_variable port_default; do
    require_literal "${env_example}" "${port_variable}=${port_default}" ".env.example primary host port"
done <<< "$(pancake_devcontainer_port_rows)"
require_literal "${env_example}" "EGRESS_NET=$(pancake_devcontainer_default_egress_network main)" ".env.example primary egress network"
require_literal "${compose_file}" "source: \${PANCAKE_GIT_COMMON_DIR:?" "docker-compose.yml Git common-dir source"
require_literal "${compose_file}" "target: \${PANCAKE_GIT_COMMON_DIR:?" "docker-compose.yml Git common-dir target"
require_literal "${env_example}" "PANCAKE_GIT_COMMON_DIR=" ".env.example Git common directory"
require_literal "${dir}/hooks/initialize.sh" "bash \"\${dir}/bin/configure.sh\"" "hooks/initialize.sh bootstraps the checkout environment"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_ROOMS_WEB_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:8000" "docker-compose.yml web host port"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_ROOMS_CAPTP_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:9099" "docker-compose.yml CapTP host port"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_ROOMS_RELAY_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:9200" "docker-compose.yml relay host port"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_ROOMS_TRACE_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:9300" "docker-compose.yml trace host port"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_OCAPNVIZ_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:5173" "docker-compose.yml ocapnviz host port"
require_literal "${compose_file}" "0.0.0.0:\${PANCAKE_DOCS_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:1990" "docker-compose.yml docs-serve host port"
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


# Every path these files name inside .devcontainer/ has to be there, in both
# the form a host runs and the form the image build reaches through
# PANCAKE_DEVCONTAINER_DIR: the image keeps the checkout's layout, so one
# rule covers both. A file moved without one of its callers is caught here
# rather than at somebody's next rebuild.
#
# The exceptions are the paths this directory deliberately does not track: a
# checkout's own .env and its pane configuration, each written locally and
# each named in prose by the files that read it.
devcontainer_untracked_paths=".env pane/panes.sh pane/panes-review.sh"
require_named_paths() {
    local file="$1" label="$2" path relative missing=0
    while IFS= read -r path; do
        relative="${path#.devcontainer/}"
        relative="${relative#\$\{PANCAKE_DEVCONTAINER_DIR\}/}"
        case " ${devcontainer_untracked_paths} " in
            *" ${relative} "*) continue ;;
        esac
        if [[ ! -e "${dir}/${relative}" ]]; then
            echo "${label} names ${path}, which is not in .devcontainer/" >&2
            missing=1
        fi
    done < <(grep -oE '(\.devcontainer|\$\{PANCAKE_DEVCONTAINER_DIR\})/[A-Za-z0-9_][A-Za-z0-9_./-]*' "${file}" |
        sed -E 's/[.,;:)]+$//' | sort -u)
    return "${missing}"
}
require_named_paths "${dockerfile}" "Dockerfile"
require_named_paths "${devcontainer_json}" "devcontainer.json"
require_named_paths "${compose_file}" "docker-compose.yml"
require_named_paths "${dir}/../ci/gates.sh" "ci/gates.sh"
require_named_paths "${dir}/../build.zig" "build.zig"
for devcontainer_workflow in "${dir}"/../.github/workflows/*.yml; do
    require_named_paths "${devcontainer_workflow}" "$(basename "${devcontainer_workflow}")"
done

# Every script here reaches its siblings through "${dir}", which by
# convention is this directory, so each of those paths has to resolve. A file
# that moves without one of its callers is the failure this catches, and it
# is the one a literal check cannot: a literal pins the old form and passes.
require_sibling_paths() {
    local file="$1" path missing=0
    while IFS= read -r path; do
        case " ${devcontainer_untracked_paths} " in
            *" ${path} "*) continue ;;
        esac
        if [[ ! -e "${dir}/${path}" ]]; then
            echo "${file#"${dir}/"} reaches \${dir}/${path}, which is not there" >&2
            missing=1
        fi
    done < <(grep -oE '\$\{dir\}/[A-Za-z0-9_][A-Za-z0-9_./-]*' "${file}" |
        sed -E 's|^\$\{dir\}/||' | sort -u)
    return "${missing}"
}
while IFS= read -r devcontainer_script; do
    require_sibling_paths "${devcontainer_script}"
done < <(find "${dir}" -name '*.sh' | sort)

# The prose beside the scripts is part of the same surface, so a link in it
# points at something that is there.
require_doc_links() {
    local file="$1" target missing=0
    while IFS= read -r target; do
        if [[ ! -e "${dir}/${target}" ]]; then
            echo "$(basename "${file}") links ${target}, which is not in .devcontainer/" >&2
            missing=1
        fi
    done < <(grep -oE '\]\([A-Za-z0-9_][A-Za-z0-9_./-]*\)' "${file}" |
        sed -E 's/^\]\((.*)\)$/\1/' | sort -u)
    return "${missing}"
}
for devcontainer_doc in "${dir}"/*.md; do
    require_doc_links "${devcontainer_doc}"
done
