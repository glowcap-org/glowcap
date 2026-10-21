#!/usr/bin/env bash
# The managed-tool maintenance front: status, ensure, update, repair.
#   tools.sh status [tool...]     offline report; missing installs are normal
#   tools.sh ensure <tool...>     install missing seeds, adopt newer seeds,
#                                 verify selections; no upstream query
#   tools.sh update <tool...>     move a harness to its upstream latest
#   tools.sh repair <tool>        reinstall the selection into a new install
#   tools.sh exec <tool> -- <cmd> prepare the selection and exec <cmd> with
#                                 the driver's environment (pinned assets)
#
# Mutating verbs require explicit tool names; there is no implicit install of
# every tool. Each requested tool is attempted and its outcome reported;
# the first failure's status is returned so a later success cannot hide an
# earlier failure. Exit codes: 1 install/verification failure, 2 upstream status-allow: event or source ordering
# query failure, 64 invalid usage, 75 lock contention.
#
# Runs inside the devcontainer only.

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Consumed by the sourced drivers
# shellcheck disable=SC2034
GLOWCAP_TOOLS_FRONT="${dir}/bin/tools.sh"

# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
# shellcheck source=../lib/update-pins-deps.sh
source "${dir}/lib/update-pins-deps.sh"
glowcap_devcontainer_init "${dir}" checksums
glowcap_require_devcontainer "bin/tools"

# shellcheck source=../tools/lib/registry.sh
source "${dir}/tools/lib/registry.sh"
# shellcheck source=../tools/lib/lifecycle.sh
source "${dir}/tools/lib/lifecycle.sh"

usage() {
    echo "usage: tools.sh status [tool...] | ensure <tool...> | update <tool...> | repair <tool> | exec <tool> -- <command...>" >&2
}

# Validate every name before any effect.
validate_tools() {
    local tool
    for tool in "$@"; do
        glowcap_tools_registry_rows | grep -q "^${tool}|" || {
            echo "tools: '${tool}' is not a managed tool; managed: $(glowcap_tools_all | tr '\n' ' ')" >&2
            return 64
        }
        # The driver file is selected by the registry: data, not a literal.
        # shellcheck source=/dev/null
        source "${dir}/tools/lib/${tool}.sh"
    done
}

# Attempt every tool and return the first failure's status, so a later
# success cannot hide an earlier failure. status-allow: event or source ordering
run_for_each() {
    local verb="$1" tool rc first_rc=0
    shift
    export GLOWCAP_TOOLS_RETRY_VERB="${verb}"
    for tool in "$@"; do
        rc=0
        "glowcap_tools_${verb}_tool" "${tool}" || rc=$?
        if [[ "${rc}" -ne 0 ]]; then
            echo "tools: ${tool}: ${verb} failed (exit ${rc})" >&2
            [[ "${first_rc}" -ne 0 ]] || first_rc="${rc}"
        fi
    done
    return "${first_rc}"
}

case "${1:-}" in
    status)
        shift
        if [[ $# -eq 0 ]]; then
            # shellcheck disable=SC2046  # a known list of tool names, one word each
            set -- $(glowcap_tools_all)
        fi
        validate_tools "$@" || exit $?
        glowcap_tools_status "$@"
        ;;
    ensure | update)
        [[ $# -ge 2 ]] || { usage; exit 64; }
        verb="${1}"
        shift
        validate_tools "$@" || exit $?
        run_for_each "${verb}" "$@"
        ;;
    repair)
        [[ $# -eq 2 ]] || { usage; exit 64; }
        validate_tools "${2}" || exit $?
        run_for_each repair "${2}"
        ;;
    exec)
        # exec <tool> -- <command...>: prepare the tool's selection, apply the
        # driver's environment, and exec the command in this process.
        [[ $# -ge 4 && "${3}" == "--" ]] || { usage; exit 64; }
        validate_tools "${2}" || exit $?
        tool="${2}"
        shift 3
        glowcap_tools_exec_command "${tool}" "$@"
        ;;
    -h | --help)
        usage
        ;;
    *)
        usage
        exit 64
        ;;
esac
