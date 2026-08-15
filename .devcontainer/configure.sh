#!/usr/bin/env bash
# Create this checkout's ignored Compose environment from its Git identity.
#
#   bash .devcontainer/configure.sh
#   bash .devcontainer/configure.sh --port-offset 10000
#   bash .devcontainer/configure.sh --egress-net existing-network
#
# The primary checkout needs no arguments. A linked worktree must provide a
# port offset; --egress-net opts into an existing host network instead of the
# isolated pancake-<worktree>-egress network created by initialize.sh. An
# existing valid .env is never overwritten.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"

usage() {
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

offset=""
egress=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port-offset | --egress-net)
            option="$1"
            shift
            if [[ $# -eq 0 || "$1" == --* ]]; then
                echo "configure.sh: ${option} needs a value" >&2
                exit 2
            fi
            if [[ "${option}" == --port-offset ]]; then
                offset="$1"
            else
                egress="$1"
            fi
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "configure.sh: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

pancake_require_host "configure.sh"
command -v git >/dev/null || { echo "configure.sh: git is not on PATH" >&2; exit 1; }
pancake_devcontainer_configure_env "${dir}" "${offset}" "${egress}"
