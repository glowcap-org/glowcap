#!/usr/bin/env bash
# Run a command in this checkout's development environment. The default selects
# its devcontainer; --local selects the host; --auto prefers a same-platform
# container and otherwise requires the complete local product toolchain.
# Finite builds share one checkout lease. Called by ./glowcap and the work skill.
set -euo pipefail

user=${GLOWCAP_DEV_USER:-vscode}

source_path=${BASH_SOURCE[0]}
while [[ -L "${source_path}" ]]; do
    source_dir=$(cd -P "$(dirname "${source_path}")" && pwd)
    source_path=$(readlink "${source_path}")
    [[ "${source_path}" = /* ]] || source_path="${source_dir}/${source_path}"
done
repo_root=$(cd -P "$(dirname "${source_path}")/../.." && pwd)
workdir=${GLOWCAP_DEV_WORKDIR:-/workspaces/glowcap}

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/mod.sh
source "${repo_root}/.devcontainer/lib/mod.sh"

selection=container
case ${1:-} in
    --local) selection=local; shift ;;
    --auto) selection=auto; shift ;;
esac

if [[ $# -eq 0 ]]; then
    set -- /bin/bash
fi

# This front always selects the declared environment. A host enters the
# worktree's container. A process already in that image stays there and runs
# from the checkout containing this script. An explicit container selection is
# still honored so a Docker-in-Docker host can target another workspace.
execution_root=${workdir}
local_root=${repo_root}
run_locally=false
if [[ ${selection} == local ]] || { glowcap_in_devcontainer && [[ -z "${GLOWCAP_DEV_CONTAINER:-}" ]]; }; then
    # The checkout is also mounted at its host path for Git's absolute worktree
    # metadata. Prefer the ordinary workspace alias when both names reach this
    # same checkout, so cache keys and diagnostics use one canonical root.
    if [[ -d "${workdir}" && "${repo_root}" -ef "${workdir}" ]]; then
        local_root=${workdir}
    fi
    execution_root=${local_root}
    run_locally=true
fi

container_id=""
container_name="${GLOWCAP_DEV_CONTAINER:-glowcap-$(glowcap_devcontainer_worktree_name "${repo_root}/.devcontainer")}"
if [[ ${run_locally} == false ]]; then
    if command -v docker >/dev/null 2>&1 && { [[ ${selection} != auto ]] || [[ $(uname -s) == Linux ]]; }; then
        if [[ -n ${GLOWCAP_DEV_CONTAINER:-} ]]; then
            container_id=$(docker ps --filter "name=^/${container_name}$" --format '{{.ID}}' | head -n 1)
        else
            container_id=$(glowcap_devcontainer_running_container "${repo_root}") || container_id=""
        fi
    fi
    if [[ -n ${container_id} && ${selection} == auto ]]; then
        container_arch=$(docker exec "${container_id}" uname -m)
        if [[ ${container_arch} != "$(uname -m)" ]]; then
            if [[ -n ${GLOWCAP_DEV_CONTAINER:-} ]]; then
                echo "glowcap-dev: selected container architecture ${container_arch} cannot build this host's executable" >&2
                exit 1
            fi
            container_id=""
        fi
    fi
    if [[ -z ${container_id} && ${selection} == auto ]]; then
        for tool in zig cargo deno wasm-bindgen python3; do
            if ! command -v "${tool}" >/dev/null 2>&1; then
                echo "glowcap-dev: no matching running devcontainer or complete local toolchain (missing ${tool}); start this checkout's devcontainer on Linux, or build locally on macOS" >&2
                exit 1
            fi
        done
        run_locally=true
        execution_root=${repo_root}
    elif [[ -z ${container_id} ]]; then
        echo "glowcap-dev: no running devcontainer for ${repo_root}; expected ${container_name}" >&2
        exit 1
    fi
fi

# Zig 0.17's build runner owns the only correct unit-test timeout: it resets
# after every test result. Add the project policy once at the agent/container
# boundary instead of wrapping an aggregate artifact in a wall-clock deadline.
if [[ ${1:-} == zig && ${2:-} == build ]]; then
    has_test_timeout=false
    for arg in "$@"; do
        [[ ${arg} == -- ]] && break
        if [[ $arg == --test-timeout ]]; then
            has_test_timeout=true
            break
        fi
    done
    if [[ $has_test_timeout == false ]]; then
        set -- zig build --test-timeout 30s "${@:3}"
    fi

    # Service steps intentionally run until interrupted. Every other build gets
    # one visible lease over this worktree's shared container resources.
    service_build=false
    for arg in "${@:3}"; do
        [[ ${arg} == -- ]] && break
        case "${arg}" in
            glowcap | docs-serve | ocapnviz-dev | rooms-chat | rooms-irc-front | rooms-irc-bridge | rooms-archive | rooms-session | rooms-server | rooms-trace-tail | rooms-web | rooms-dev)
                service_build=true
                break
                ;;
        esac
    done
    if [[ ${service_build} == false ]]; then
        set -- "${execution_root}/.devcontainer/bin/build-lease" "$@"
    fi
fi

if [[ ${run_locally} == true ]]; then
    cd "${local_root}"
    exec "$@"
fi

# A service's lifetime belongs to the terminal that launched it. Agent runners
# must request a PTY explicitly. Without one, interrupting the Docker client
# disconnects it and leaves the service tree running in the container.
if [[ ${service_build:-false} == true && ! -t 0 ]]; then
    echo "glowcap-dev: a host-side service build requires a terminal so Ctrl-C reaches its container process tree" >&2
    exit 2
fi

tty_args=(-i)
if [[ -t 0 ]]; then
    tty_args=(-it)
fi

exec docker exec "${tty_args[@]}" --user "$user" --workdir "$workdir" "$container_id" "$@"
