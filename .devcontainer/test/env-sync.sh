#!/usr/bin/env bash
# Fail if devcontainer pins, mounts, names, structure, or host lifecycle
# contracts drift. Pure file checks, so it runs anywhere, host or container.
# Its sibling test/host-invariants.sh covers behaviour; `zig build
# source-check` runs both.

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_source_pins "${dir}"

dockerfile="${dir}/Dockerfile"
devcontainer_json="${dir}/devcontainer.json"
compose_file="${dir}/docker-compose.yml"
env_example="${dir}/.env.example"
cli_rule="${dir}/../.agents/rules/cli.md"

# grep -F literal. Escape `$` and backticks in double quotes; single quotes
# around backticks fail post-create's shellcheck (SC2016) and block container open.
require_literal() {
    local file="$1"
    local needle="$2"
    local label="$3"
    if ! grep -Fq -- "${needle}" "${file}"; then
        echo "${label}: expected literal '${needle}' in ${file}" >&2
        return 1
    fi
}

require_line() {
    local file="$1"
    local line="$2"
    local label="$3"
    if ! grep -Fxq -- "${line}" "${file}"; then
        echo "${label}: expected exact line '${line}' in ${file}" >&2
        return 1
    fi
}

require_absent() {
    local file="$1"
    local needle="$2"
    local label="$3"
    if grep -Fq -- "${needle}" "${file}"; then
        echo "${label}: unexpected '${needle}' in ${file}" >&2
        return 1
    fi
}

# A Dockerfile and a deno.json cannot source pins.sh, so a few pins are restated
# in them. Those restatements are listed once, in lib/update-pins-companions.sh,
# so `update-pins.sh bump` can rewrite them. This reads the same table rather
# than repeating it, which is what keeps that list the only one: a row added
# there is checked from the next run, with no second place to remember.
#
# Asking for exactly the text the bump searches for also checks the bump itself.
# Passing one version as both the old and the new form asks each row what it
# looks like at the version pinned right now, and that is the anchor the next
# bump has to find.
# shellcheck source=../lib/update-pins-deps.sh
source "${dir}/lib/update-pins-deps.sh"
# shellcheck source=../lib/update-pins-companions.sh
source "${dir}/lib/update-pins-companions.sh"
for pin_dep in ${GLOWCAP_PINS_DEPS}; do
    pin_var="$(glowcap_pins_dep_var "${pin_dep}")"
    while IFS=$'\t' read -r companion_path companion_literal _; do
        [[ -n "${companion_path}" ]] || continue
        require_literal "${dir}/../${companion_path}" "${companion_literal}" \
            "${companion_path} ${pin_dep} pin"
    done < <(glowcap_pins_companions "${pin_dep}" "${!pin_var}" "${!pin_var}")
done

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
require_literal "${devcontainer_json}" "\"UV_CACHE_DIR\": \"${UV_CACHE_DIR}\"" "devcontainer.json UV_CACHE_DIR"
require_literal "${devcontainer_json}" "\"npm_config_cache\": \"${NPM_CACHE_DIR}\"" "devcontainer.json npm_config_cache"
require_literal "${devcontainer_json}" "\"PIP_CACHE_DIR\": \"${PIP_CACHE_DIR}\"" "devcontainer.json PIP_CACHE_DIR"
require_literal "${devcontainer_json}" "\"PLAYWRIGHT_BROWSERS_PATH\": \"${PLAYWRIGHT_BROWSERS_PATH}\"" "devcontainer.json PLAYWRIGHT_BROWSERS_PATH"
require_literal "${devcontainer_json}" "\"CLAUDE_CONFIG_DIR\": \"${CLAUDE_CONFIG_DIR}\"" "devcontainer.json CLAUDE_CONFIG_DIR"
require_literal "${devcontainer_json}" "\"CURSOR_CONFIG_DIR\": \"${CURSOR_STATE_DIR}\"" "devcontainer.json CURSOR_CONFIG_DIR"
require_literal "${devcontainer_json}" "\"CURSOR_DATA_DIR\": \"${CURSOR_STATE_DIR}\"" "devcontainer.json CURSOR_DATA_DIR"
require_literal "${devcontainer_json}" '"zls.enable": true' "devcontainer.json enables the installed ZLS"

require_literal "${dockerfile}" "npm_config_cache=${NPM_CACHE_DIR}" "Dockerfile npm_config_cache"
require_literal "${dockerfile}" "PIP_CACHE_DIR=${PIP_CACHE_DIR}" "Dockerfile PIP_CACHE_DIR"
require_literal "${dockerfile}" "PATH=/home/vscode/.cache/glowcap/cargo/bin:" "Dockerfile runtime cargo bin on PATH"
# Local Zig cache is a per-worktree Docker volume with daemon-native filesystem
# semantics on native Linux and Docker Desktop. The host bind remains the
# authority for shared download caches.
# uv's download cache is runtime-only so the image layer does not fill a
# directory the host bind then hides.
require_absent "${dockerfile}" "ZIG_LOCAL_CACHE_DIR=" "Dockerfile must not set ZIG_LOCAL_CACHE_DIR"
require_absent "${dockerfile}" "ZIG_LOCAL_PKG_DIR=" "Dockerfile must not set ZIG_LOCAL_PKG_DIR"
require_absent "${dockerfile}" "UV_CACHE_DIR=" "Dockerfile must not set UV_CACHE_DIR"
require_absent "${devcontainer_json}" "ZIG_LOCAL_CACHE_DIR" "devcontainer.json must not pin ZIG_LOCAL_CACHE_DIR (Compose interpolates the worktree)"
require_absent "${devcontainer_json}" "ZIG_LOCAL_PKG_DIR" "devcontainer.json must not pin ZIG_LOCAL_PKG_DIR (Compose interpolates the worktree)"
require_absent "${devcontainer_json}" "type=volume" "devcontainer.json owns host binds; the Zig volume belongs in Compose"
require_literal "${devcontainer_json}" "source=\${localEnv:HOME}/.cache/glowcap,target=${GLOWCAP_CACHE_DIR},type=bind" "devcontainer.json glowcap cache bind"
require_literal "${compose_file}" "ZIG_LOCAL_CACHE_DIR: ${ZIG_WORK_CACHE_DIR}/zig-local" "docker-compose.yml ZIG_LOCAL_CACHE_DIR"
require_literal "${compose_file}" "ZIG_LOCAL_PKG_DIR: ${ZIG_WORK_CACHE_DIR}/zig-pkg" "docker-compose.yml ZIG_LOCAL_PKG_DIR"
require_line "${compose_file}" "        source: glowcap-dev-zig-work" "docker-compose.yml Zig work-cache volume source"
require_line "${compose_file}" "        target: ${ZIG_WORK_CACHE_DIR}" "docker-compose.yml Zig work-cache volume target"
require_line "${compose_file}" "    name: glowcap-dev-\${GLOWCAP_WORKTREE:?Run bash .devcontainer/bin/configure.sh}-zig-work" "docker-compose.yml per-worktree Zig volume name"
require_literal "${dockerfile}" "/home/vscode/.cache/glowcap" "Dockerfile glowcap cache mount point"
require_literal "${dockerfile}" "${ZIG_WORK_CACHE_DIR}" "Dockerfile Zig volume mount point"
require_literal "${cli_rule}" 'glowcap-dev-<worktree>-zig-work' "CLI rule names the per-worktree Zig volume"
require_literal "${devcontainer_json}" '"workspaceFolder": "/workspaces/glowcap"' "devcontainer.json workspace path"
require_literal "${dir}/hooks/initialize.sh" 'glowcap_devcontainer_host_home_bind_rows' "hooks/initialize.sh creates every host-home bind source"
require_literal "${dir}/hooks/initialize.sh" 'glowcap_devcontainer_host_cache_layout' "hooks/initialize.sh creates glowcap cache subdirs"
require_literal "${dir}/hooks/initialize.sh" 'glowcap_devcontainer_host_cache_layout_text' "hooks/initialize.sh writes LAYOUT from the one inventory"
require_literal "${dir}/hooks/post-create.sh" 'glowcap_devcontainer_host_home_bind_rows' "hooks/post-create.sh checks every host-home bind"
require_literal "${dir}/hooks/post-create.sh" 'test/zig-cache-filesystem.py' "hooks/post-create.sh proves the Zig cache filesystem supports atomic response files"
expected_host_mounts=0
owned_dir_block="$(sed -n '/^sudo chown -R vscode:vscode /p' "${dir}/hooks/post-create.sh")"
while IFS=: read -r host_relative host_target; do
    expected_host_mounts=$((expected_host_mounts + 1))
    require_literal "${devcontainer_json}" "source=\${localEnv:HOME}/${host_relative},target=${host_target},type=bind" "devcontainer.json shared host-home mount"
    if grep -qE "^[[:space:]]*target: ${host_target}[[:space:]]*$" "${compose_file}"; then
        echo "docker-compose.yml: ${host_target} must come from the shared host bind in devcontainer.json" >&2
        exit 1
    fi
    if grep -Fq "${host_target}" <<< "${owned_dir_block}"; then
        echo "post-create.sh: shared host path must not be recursively owned by the container: ${host_target}" >&2
        exit 1
    fi
done <<< "$(glowcap_devcontainer_host_home_bind_rows)"
actual_host_mounts="$(grep -Fc "source=\${localEnv:HOME}/" "${devcontainer_json}")"
if [[ "${actual_host_mounts}" -ne "${expected_host_mounts}" ]]; then
    echo "devcontainer.json: every host-home mount must be declared by glowcap_devcontainer_host_home_bind_rows" >&2
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
    done <<< "$(glowcap_devcontainer_host_state_rows)"
    echo "${label}=${wanted} is not a shared host-state mount target" >&2
    return 1
}
require_shared_target CLAUDE_CONFIG_DIR "${CLAUDE_CONFIG_DIR}"
require_shared_target CURSOR_CONFIG_DIR "${CURSOR_STATE_DIR}"
require_shared_target CURSOR_DATA_DIR "${CURSOR_STATE_DIR}"
require_shared_target CURSOR_AUTH_DIR "${CURSOR_AUTH_DIR}"
require_literal "${dockerfile}" "${CURSOR_AUTH_DIR}" "Dockerfile Cursor Linux auth directory"

require_literal "${compose_file}" "working_dir: /workspaces/glowcap" "docker-compose.yml workspace path"
require_literal "${dir}/../.agents/skills/work/bin/glowcap-dev" 'GLOWCAP_DEV_WORKDIR:-/workspaces/glowcap' "glowcap-dev workspace path"
require_literal "${dir}/lib/launcher.sh" "tmux list-panes -s -t \"\${window_target}\"" "the dead-session sweep qualifies list-panes with a session and window target"
require_literal "${dir}/lib/launcher.sh" "pane/host/.bashrc" "pane shells start through the host half of the pane runtime"
require_literal "${dir}/bin/enter-grid.sh" "-P -F '#{pane_id}'" "enter-grid.sh addresses grid panes by pane id"
require_literal "${dir}/hooks/post-create.sh" "find \"\${dir}\" -name '*.sh'" "the lint reaches every shell file in the tree, not only the top of it"
require_literal "${dir}/hooks/post-create.sh" "command -v zsh" "post-create requires the workspace zsh the pane runtime uses"
require_literal "${dockerfile}" "util-linux zsh" "Dockerfile installs zsh, the pane runtime's container shell"
require_literal "${dockerfile}" "-s /bin/zsh vscode" "Dockerfile workspace user login shell is zsh"
require_literal "${dir}/pane/host/.bashrc" "\"\${container}\" /bin/zsh" "the pane runtime execs the image's /bin/zsh"
require_literal "${dir}/image/verify-toolchains.sh" "/bin/zsh --version" "image verify checks the zsh the pane runtime execs"
require_absent "${dir}/image/verify-toolchains.sh" "GLOWCAP_DEVCONTAINER_DIR:-" "verify-toolchains locates itself like every other image script"
require_literal "${dir}/hooks/post-create.sh" "bash \"\${dir}/image/verify-toolchains.sh\"" "post-create verifies the checkout's pins against the installed tools"
require_absent "${dir}/hooks/post-create.sh" "GLOWCAP_DEVCONTAINER_DIR=\"\${dir}\" bash" "post-create does not retarget verify-toolchains via GLOWCAP_DEVCONTAINER_DIR"
require_literal "${dir}/hooks/post-create.sh" '-name compiled' "post-create removes leftover Racket bytecode a rebuild leaves on the workspace bind"
require_literal "${dir}/hooks/post-create.sh" "conformance/bootstrap-submodules.sh" "post-create fills the conformance submodules so every worktree is a complete checkout"
require_literal "${dir}/bin/enter-grid.sh" "no worktrees to open" "enter-grid.sh refuses an empty grid instead of expanding an unset column"
require_literal "${dir}/README.md" "verifies host binds are writable" "README first-open checks host binds, it does not chown a volume"
require_literal "${dir}/README.md" "The first locked cargo build" "README says an empty cargo/ home fills from a locked crate build"
require_literal "${dir}/README.md" "Racket \`compiled/\`" "README says post-create deletes leftover Racket bytecode"
require_literal "${dir}/image/rust.sh" "the cargo/ slice of the host bind" "rust.sh runtime cargo home is the host bind"
require_literal "${dir}/image/playwright.sh" "runtime host bind" "playwright.sh npm cache is a host bind, not a volume"
require_literal "${dir}/lib/launcher.sh" "panes_name=panes.sh" "the launchers name the panes.sh contract the runtime defaults to"
require_literal "${dir}/bin/container-id.sh" "glowcap_devcontainer_checkout_entry" "the container lookup finds that checkout's own up.sh"
require_literal "${dir}/bin/container-id.sh" "bash \"\${lifecycle}\"" "the container lookup runs the lifecycle it found"
require_literal "${dir}/lib/launcher.sh" "glowcap_devcontainer_checkout_entry" "launchers accept a checkout whose up.sh has not moved into bin/"
require_literal "${dir}/pane/host/.bashrc" ".devcontainer/pane/container" "the host half of the runtime opens the container half"
require_literal "${dir}/pane/host/.bashrc" '[[ -f ~/.bashrc ]] && source ~/.bashrc' "the host pane shell is initialized before it enters the container"
require_literal "${dir}/pane/host/.bashrc" "GLOWCAP_TMUX_DETACH_STATUS=" "the host half declares the status that leaves the container and keeps the pane"
require_literal "${dir}/pane/host/.bashrc" "GLOWCAP_TMUX_PANES_NAME:-panes.sh" "the host half defaults to the panes.sh contract"
require_literal "${dir}/pane/container/.zshrc" '[[ -f ~/.zshrc ]] && source ~/.zshrc' "the container pane shell is initialized before the startup command"
require_literal "${dir}/pane/container/.zshrc" "GLOWCAP_TMUX_PANES_FILE" "the container half reads the panes file the host half named"
require_literal "${dir}/pane/container/.zshrc" "../host/.bashrc" "the container half names the host half it answers to"
require_literal "${dir}/pane/container/.zshrc" "GLOWCAP_TMUX_DETACH_STATUS" "the container half exits with the status the host half declared"
require_literal "${compose_file}" "container_name: glowcap-dev-\${GLOWCAP_WORKTREE:?Run bash .devcontainer/bin/configure.sh}" "docker-compose.yml worktree container name"
require_literal "${compose_file}" "image: vsc-glowcap-dev-\${GLOWCAP_WORKTREE:?Run bash .devcontainer/bin/configure.sh}" "docker-compose.yml worktree image name"
require_literal "${compose_file}" "GLOWCAP_WORKTREE: \${GLOWCAP_WORKTREE:?Run bash .devcontainer/bin/configure.sh}" "docker-compose.yml worktree environment"
require_literal "${compose_file}" "GLOWCAP_CHECKOUT_DIR: \${GLOWCAP_CHECKOUT_DIR:?Run bash .devcontainer/bin/configure.sh}" "docker-compose.yml checkout environment"
require_literal "${env_example}" "GLOWCAP_WORKTREE=main" ".env.example primary worktree default"
require_literal "${env_example}" "GLOWCAP_CHECKOUT_DIR=" ".env.example checkout directory"
while IFS=: read -r port_variable port_default; do
    require_literal "${env_example}" "${port_variable}=${port_default}" ".env.example primary host port"
done <<< "$(glowcap_devcontainer_port_rows)"
require_literal "${env_example}" "EGRESS_NET=$(glowcap_devcontainer_default_egress_network main)" ".env.example primary egress network"
require_literal "${compose_file}" "source: \${GLOWCAP_CHECKOUT_DIR:?" "docker-compose.yml checkout source"
require_literal "${compose_file}" "target: \${GLOWCAP_CHECKOUT_DIR:?" "docker-compose.yml checkout target"
require_literal "${compose_file}" "source: \${GLOWCAP_GIT_COMMON_DIR:?" "docker-compose.yml Git common-dir source"
require_literal "${compose_file}" "target: \${GLOWCAP_GIT_COMMON_DIR:?" "docker-compose.yml Git common-dir target"
require_literal "${env_example}" "GLOWCAP_GIT_COMMON_DIR=" ".env.example Git common directory"
require_literal "${dir}/hooks/initialize.sh" "bash \"\${dir}/bin/configure.sh\"" "hooks/initialize.sh bootstraps the checkout environment"
require_literal "${compose_file}" "127.0.0.1:\${GLOWCAP_ROOMS_WEB_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:8080" "docker-compose.yml web host port"
require_literal "${compose_file}" "127.0.0.1:\${GLOWCAP_ROOMS_CAPTP_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:9099" "docker-compose.yml CapTP host port"
require_literal "${compose_file}" "127.0.0.1:\${GLOWCAP_ROOMS_RELAY_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:9200" "docker-compose.yml relay host port"
require_literal "${compose_file}" "127.0.0.1:\${GLOWCAP_ROOMS_TRACE_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:9300" "docker-compose.yml trace host port"
require_literal "${compose_file}" "127.0.0.1:\${GLOWCAP_OCAPNVIZ_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:5173" "docker-compose.yml ocapnviz host port"
require_literal "${compose_file}" "127.0.0.1:\${GLOWCAP_DOCS_HOST_PORT:?Run bash .devcontainer/bin/configure.sh}:1990" "docker-compose.yml docs-serve host port"
require_literal "${compose_file}" "GLOWCAP_ROOMS_DEV_HOST: 0.0.0.0" "docker-compose.yml Rooms Vite bind"
require_literal "${compose_file}" "OCAPNVIZ_HOST: 0.0.0.0" "docker-compose.yml ocapnviz Vite bind"
require_literal "${compose_file}" "DOCS_SERVE_HOST: 0.0.0.0" "docker-compose.yml docs-serve bind"
require_line "${compose_file}" "    init: true" "docker-compose.yml reaps orphaned tool grandchildren"
require_literal "${dir}/../apps/ocapnviz/vite-dev-listen.ts" "allowedHosts: true" "ocapnviz Vite Host-header policy for a wide bind"
require_literal "${dir}/../site/docs-serve.sh" 'DOCS_SERVE_HOST:-127.0.0.1' "docs-serve.sh forwards the container-wide bind"

# Every bind target under the container's home must itself exist, owned by
# vscode, in the image. Docker creates a missing mount path as root, and it
# creates missing parents the same way. A direct child of home is the same
# case as a nested path: the mount point has to be created, not only its
# parent.
#
# Authority is the host-bind table plus any compose target under home, so a
# row added to the table still fails until the Dockerfile mkdir covers it.
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
    if ! covered "${target}"; then
        echo "a host bind mounts ${target}, but ${dockerfile} never creates it." >&2
        echo "  Docker would create it as root and the container's own user could not write beside it." >&2
        echo "  Add ${target} to the vscode user-space 'mkdir -p' in the Dockerfile." >&2
        exit 1
    fi
done <<EOF
$(while IFS=: read -r _ host_target; do printf '%s\n' "${host_target}"; done <<< "$(glowcap_devcontainer_host_home_bind_rows)")
$(sed -n "s|^ *target: \(${home_dir}[^ ]*\) *$|\1|p" "${compose_file}")
EOF


# Every path these files name inside .devcontainer/ has to be there, in both
# the form a host runs and the form the image build reaches through
# GLOWCAP_DEVCONTAINER_DIR: the image keeps the checkout's layout, so one
# rule covers both. A file moved without one of its callers is caught here
# rather than at somebody's next rebuild.
#
# The exceptions are the paths this directory deliberately does not track: a
# checkout's own .env and its pane configuration, each written locally and
# each named in prose by the files that read it.
devcontainer_untracked() {
    case "$1" in
        .env | pane/panes.sh | pane/panes-*.sh) return 0 ;;
    esac
    return 1
}
require_named_paths() {
    local file="$1" label="$2" path relative copied_source missing=0
    while IFS= read -r path; do
        relative="${path#.devcontainer/}"
        relative="${relative#\$\{GLOWCAP_DEVCONTAINER_DIR\}/}"
        if devcontainer_untracked "${relative}"; then
            continue
        fi
        if [[ ! -e "${dir}/${relative}" ]]; then
            # A literal COPY may install a product-owned manifest beside the
            # installers. Verify its actual source instead of demanding a
            # second, drifting copy of that manifest under .devcontainer/.
            copied_source=""
            if [[ "${file}" == "${dockerfile}" ]]; then
                copied_source="$(awk -v destination="${path}" '
                    $1 == "COPY" && NF == 3 {
                        gsub(/"/, "", $2); gsub(/"/, "", $3);
                        if ($3 == destination) print $2;
                    }' "${dockerfile}")"
            fi
            if [[ -n "${copied_source}" && -f "${dir}/../${copied_source}" ]]; then
                continue
            fi
            echo "${label} names ${path}, which is not in .devcontainer/" >&2
            missing=1
        fi
    done < <(grep -oE '(\.devcontainer|\$\{GLOWCAP_DEVCONTAINER_DIR\})/[A-Za-z0-9_][A-Za-z0-9_./-]*' "${file}" |
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
        if devcontainer_untracked "${path}"; then
            continue
        fi
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

# Every installer in image/ is reached from the Dockerfile or from another
# installer. verify-toolchains.sh is a checker, not a caller, so a mention
# in an error string there does not count. An added image/*.sh that nothing
# invokes is invisible until a rebuild that was supposed to include it does
# not.
installer_reached() {
    local name="$1" other
    if grep -Fq "image/${name}" "${dockerfile}"; then
        return 0
    fi
    for other in "${dir}"/image/*.sh; do
        [[ "$(basename "${other}")" == "${name}" ]] && continue
        [[ "$(basename "${other}")" == verify-toolchains.sh ]] && continue
        if grep -Fq "image/${name}" "${other}"; then
            return 0
        fi
    done
    return 1
}
while IFS= read -r installer; do
    name="$(basename "${installer}")"
    if ! installer_reached "${name}"; then
        echo "image/${name} is never invoked from the Dockerfile or another image installer" >&2
        exit 1
    fi
done < <(find "${dir}/image" -name '*.sh' | sort)

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
for devcontainer_doc in "${dir}"/*.md "${dir}"/docs/*.md; do
    require_doc_links "${devcontainer_doc}"
done

# A shell file here is either run or sourced, and its committed mode says which.
# Read the Git index rather than `test -x`: macOS bind mounts can report every
# file executable inside the Linux container even when both Git and the host
# filesystem record 0644. Anything under bin/, hooks/, image/, and test/ is
# invoked, so it is 100755; lib/ and the two pin tables are sourced, so they are
# 100644.
git_mode() {
    local relative="${1#"${dir}/../"}"
    git -C "${dir}/.." ls-files --stage -- "${relative}" | awk 'NR == 1 { print $1 }'
}

while IFS= read -r shell_file; do
    if [[ "$(git_mode "${shell_file}")" != 100755 ]]; then
        echo "${shell_file#"${dir}/"}: invoked directly, so it must be executable" >&2
        exit 1
    fi
done < <(find "${dir}/bin" "${dir}/hooks" "${dir}/image" "${dir}/test" -name '*.sh' | sort)

while IFS= read -r shell_file; do
    if [[ "$(git_mode "${shell_file}")" != 100644 ]]; then
        echo "${shell_file#"${dir}/"}: sourced, never run, so it must not be executable" >&2
        exit 1
    fi
done < <(
    find "${dir}/lib" -name '*.sh' | sort
    printf '%s\n' "${dir}/pins.sh" "${dir}/checksums.sh"
)

# ShellCheck treats `--` on a directive line as another key (`SC1072`), then
# fails the parse. post-create's shellcheck of this tree then blocks container
# open. A comment belongs on the next line, the way pins.sh already writes it.
# The file list is the same one post-create lints: every `*.sh` here, the pane
# runtime's host half, and the repo-root shim.
while IFS= read -r shell_file; do
    matches=""
    grep_status=0
    matches="$(grep -nE '^[[:space:]]*#[[:space:]]*shellcheck[[:space:]].*--' "${shell_file}")" || grep_status=$?
    if [[ "${grep_status}" -eq 0 ]]; then
        echo "${shell_file#"${dir}/"}: a shellcheck directive cannot use -- for a comment; put the comment on the next line" >&2
        echo "${matches}" >&2
        exit 1
    fi
    if [[ "${grep_status}" -ne 1 ]]; then
        echo "${shell_file#"${dir}/"}: failed to scan for invalid shellcheck directives" >&2
        exit 1
    fi
done < <(
    find "${dir}" -name '*.sh' | sort
    printf '%s\n' "${dir}/pane/host/.bashrc" "${dir}/../glowcap"
)
