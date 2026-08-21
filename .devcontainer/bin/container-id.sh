#!/usr/bin/env bash
# Print the id of this checkout's running container, starting it first when
# it is not running, or when a mode asks for the lifecycle regardless.
#
#   bash .devcontainer/bin/container-id.sh              start it only if it is down
#   bash .devcontainer/bin/container-id.sh --up         run the lifecycle first
#   bash .devcontainer/bin/container-id.sh --rebuild    rebuild it first
#   bash .devcontainer/bin/container-id.sh --no-cache   rebuild it without the cache
#   bash .devcontainer/bin/container-id.sh <checkout>   answer for another checkout
#
# This is the one answer to "which container is this checkout's, and is it
# up". The tmux launchers ask before they open a session, and a pane's host
# shell asks every time it enters, so a container stopped or rebuilt under a
# live pane comes back without the reader leaving the pane. A checkout other
# than this one can be named, which is what lets one launcher open a grid
# across several worktrees; the lifecycle itself is still run by that
# checkout's own entry point, so each column keeps its own configuration and
# its own idea of which ports it publishes.
#
# The id goes to stdout and nothing else does, so a caller can read it
# directly. Everything the lifecycle prints goes to stderr, where a reader
# watching a pane still sees it.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checkout=""
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_require_host "container-id.sh"

mode=if-missing
for argument in "$@"; do
    case "${argument}" in
        --up) mode=up ;;
        --rebuild) mode=rebuild ;;
        --no-cache) mode=no-cache ;;
        -h | --help)
            awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        -*)
            echo "container-id.sh: unknown option: ${argument}" >&2
            exit 2
            ;;
        *)
            if [[ -n "${checkout}" ]]; then
                echo "container-id.sh: name at most one checkout" >&2
                exit 2
            fi
            checkout="${argument}"
            ;;
    esac
done

if [[ -z "${checkout}" ]]; then
    checkout="$(dirname "${dir}")"
fi
if [[ ! -d "${checkout}" ]]; then
    echo "container-id.sh: checkout does not exist: ${checkout}" >&2
    exit 1
fi
if ! lifecycle="$(pancake_devcontainer_checkout_entry "${checkout}" up.sh)"; then
    echo "container-id.sh: checkout has no devcontainer lifecycle entry point: ${checkout}" >&2
    exit 1
fi

if [[ "${mode}" == if-missing ]]; then
    if container="$(pancake_devcontainer_running_container "${checkout}" 2>/dev/null)"; then
        printf '%s\n' "${container}"
        exit 0
    fi
    mode=up
fi

# The checkout's own entrypoint is the lifecycle authority: it reuses a
# current container, starts or creates a missing one, and builds when the
# configuration requires it.
case "${mode}" in
    rebuild) bash "${lifecycle}" --rebuild >&2 ;;
    no-cache) bash "${lifecycle}" --no-cache >&2 ;;
    up) bash "${lifecycle}" >&2 ;;
esac
pancake_devcontainer_running_container "${checkout}"
