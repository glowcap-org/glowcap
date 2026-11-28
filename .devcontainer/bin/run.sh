#!/usr/bin/env bash
# Run a command in this checkout's development environment. The default selects
# its devcontainer; --local selects the host; --auto prefers a same-platform
# container and otherwise requires the complete local product toolchain.
# --env NAME=VALUE supplies an explicit child environment override. Finite
# builds share one checkout lease. Called by ./glowcap and the work skill.
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
forwarded_env=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --local) selection=local; shift ;;
        --auto) selection=auto; shift ;;
        --env)
            if [[ $# -lt 2 || ! $2 =~ ^[a-zA-Z_][a-zA-Z_0-9]*= ]]; then
                echo "glowcap-dev: --env requires NAME=VALUE" >&2
                exit 2
            fi
            forwarded_env+=("$2")
            shift 2
            ;;
        *) break ;;
    esac
done

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
container_name="${GLOWCAP_DEV_CONTAINER:-}"
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
        echo "glowcap-dev: no running devcontainer for ${repo_root}; expected ${container_name:-a container labeled for this checkout}" >&2
        exit 1
    fi
fi

# Apply container build defaults at the front as well as Compose, so an
# already-running container gets the same cache without a service restart.
# Explicit --env values and inherited caller settings take precedence.
if [[ ${run_locally} == false ]] || glowcap_in_devcontainer; then
    glowcap_devcontainer_source_pins "${repo_root}/.devcontainer"
    while IFS=: read -r key value; do
        supplied=false
        for assignment in ${forwarded_env[@]+"${forwarded_env[@]}"}; do
            [[ ${assignment} == "${key}="* ]] && supplied=true
        done
        if [[ ${supplied} == false ]]; then
            forwarded_env+=("${key}=${!key:-${value}}")
        fi
    done < <(glowcap_devcontainer_build_env_rows)
fi

# Zig 0.17's build runner owns the only correct unit-test timeout: it resets
# after every test result. Add the project policy once at the agent/container
# boundary instead of wrapping an aggregate artifact in a wall-clock deadline.
if [[ ${1:-} == zig && ${2:-} == build ]]; then
    has_test_timeout=false
    value_for=""
    project_build=true
    release_preset=false
    other_step=""
    service_step=""
    inspect_only=false
    for arg in "${@:3}"; do
        if [[ -n ${value_for} ]]; then
            if [[ ${value_for} == --build-file ]]; then
                build_file=${arg}
                [[ ${build_file} == /* ]] || build_file="${repo_root}/${build_file}"
                if [[ ! ${build_file} -ef ${repo_root}/build.zig && ${arg} != "${execution_root}/build.zig" ]]; then
                    project_build=false
                fi
            fi
            value_for=""
            continue
        fi
        case "${arg}" in
            --) break ;;
            --test-timeout) has_test_timeout=true; value_for=${arg} ;;
            -p | --prefix | --prefix-lib-dir | --prefix-exe-dir | --prefix-include-dir | \
                --search-prefix | --sysroot | --libc | --system | --libc-runtimes | \
                --color | --error-style | --multiline-errors | --summary | --maxrss | --debounce | \
                --fork | --error-limit | --build-file | --cache-dir | --seed | --debug-log)
                value_for=${arg} ;;
            -h | --help | -l | --list-steps | --print-configuration | --print-configuration-path | --fetch | --fetch=*)
                inspect_only=true ;;
            -*) ;;
            glowcap-release) release_preset=true ;;
            glowcap | site-serve | ocapnviz-dev | rooms-chat | rooms-irc-server | rooms-irc-bridge | rooms-archive | rooms-bot | rooms-session | rooms-server | rooms-trace-tail | rooms-web | rooms-dev)
                service_step=${service_step:-${arg}}
                other_step=${arg} ;;
            *) other_step=${arg} ;;
        esac
    done
    if [[ ${project_build} == false || ${inspect_only} == true ]]; then
        service_step=""
    elif [[ ${release_preset} == true && -n ${other_step} ]]; then
        echo "glowcap-dev: run 'zig build glowcap-release' separately from '${other_step}'. The release preset starts its own build that writes to the same Zig library directory." >&2
        exit 2
    fi
    if [[ ${has_test_timeout} == false ]]; then
        set -- zig build --test-timeout 30s "${@:3}"
    fi

    # Service steps run until interrupted. Every other build gets
    # one visible lease over this worktree's shared container resources.
    case "${service_step}" in
        site-serve | rooms-dev | rooms-web | rooms-server)
            echo "glowcap-dev: preparing ${service_step}; the service has not started yet. Wait for its listening address." >&2
            if [[ ${service_step} != site-serve ]]; then
                echo "glowcap-dev: a cold Rooms build downloads dependencies and compiles Zig and Rust; browser commands also prepare WebAssembly and UI assets. This can take several minutes. Later runs reuse build caches." >&2
            fi
            ;;
    esac
    if [[ -z ${service_step} ]]; then
        set -- "${execution_root}/.devcontainer/bin/build-lease" "$@"
    fi
fi

if [[ ${run_locally} == true ]]; then
    cd "${local_root}"
    for assignment in ${forwarded_env[@]+"${forwarded_env[@]}"}; do
        export "${assignment?}"
    done
    exec "$@"
fi

# A service's lifetime belongs to the terminal that launched it. Agent runners
# must request a PTY explicitly. Without one nobody can press Ctrl-C, and a
# runner that kills this front outright leaves the service tree running in the
# container.
if [[ -n ${service_step:-} && ! -t 0 ]]; then
    echo "glowcap-dev: a host-side service build requires a terminal so Ctrl-C reaches its container process tree" >&2
    exit 2
fi

# With a terminal, docker exec makes the command the foreground process group
# of the container's terminal, where Ctrl-C reaches it. Without one, setsid
# gives the command a group of its own.
tty_args=(-i)
own_group=(setsid --wait)
if [[ -t 0 ]]; then
    tty_args=(-it)
    own_group=()
fi

# The lease runs inside the container, so a caller's choice to wait for it
# must cross the exec boundary.
env_args=()
if [[ -n ${GLOWCAP_BUILD_LEASE_TIMEOUT+set} ]]; then
    env_args+=(--env "GLOWCAP_BUILD_LEASE_TIMEOUT=${GLOWCAP_BUILD_LEASE_TIMEOUT}")
fi
for assignment in ${forwarded_env[@]+"${forwarded_env[@]}"}; do
    env_args+=(--env "${assignment}")
done

exec_args=("${tty_args[@]}" ${env_args[@]+"${env_args[@]}"} --user "$user" --workdir "$workdir" "$container_id")

# docker exec forwards no signal, and its command outlives the client: stopping
# this front or closing its terminal would leave the command running in the
# container, holding its lease or its ports. Record the command's container
# process group and signal that group when this front is stopped. The recording
# shell traps Ctrl-C so it outlives the command and removes its record. A stop
# removes the record itself.
group_file="/tmp/glowcap-dev-front-$$-${RANDOM}.pgid"
client=""

# shellcheck disable=SC2317 # Signal traps invoke this while finish_client waits.
stop_group() {
    trap - TERM INT HUP
    # A stop can arrive before the command records its group. Ask again while
    # the client that starts the command lives, for a shorter time once that
    # client is gone, and never without end.
    local asks=300 grace=20
    # shellcheck disable=SC2016 # expanded by the container shell
    until docker exec "$container_id" sh -c \
        'group=$(cat "$0" 2>/dev/null) && [ -n "$group" ] || exit 1; kill -TERM "-$group"; rm -f "$0"' "$group_file"; do
        asks=$((asks - 1))
        if [[ -z ${client} ]] || ! kill -0 "$client" 2>/dev/null; then
            grace=$((grace - 1))
        fi
        [[ ${asks} -gt 0 && ${grace} -gt 0 ]] || break
        sleep 0.1
    done
    # The client ends with a status of its own; this front reports the signal.
    if [[ -n ${client} ]]; then
        wait "$client" || true
    fi
    exit "$1"
}
trap 'stop_group 143' TERM
trap 'stop_group 130' INT
trap 'stop_group 129' HUP

# shellcheck disable=SC2016 # expanded by the container shell
docker exec "${exec_args[@]}" ${own_group[@]+"${own_group[@]}"} sh -c \
    'trap : INT; echo "$$" > "$0"; "$@"; status=$?; rm -f "$0"; exit "$status"' "$group_file" "$@" <&0 &
client=$!

finish_client() {
    # Bash parses the complete function before waiting. Checkout edits cannot
    # change a later read offset or replace the actual child status on return.
    local status=0
    wait "$client" || status=$?
    exit "$status"
}
finish_client
