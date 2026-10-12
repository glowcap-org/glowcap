#!/usr/bin/env bash
# The managed-tool dispatcher. The image links every managed command name
# (claude, codex, opencode, agent, cursor-agent) to this file; the invoked
# name selects the tool. Resolve this script through its own real path,
# the links dangle during the image build and resolve once the workspace
# bind lands, exactly like the repo-root glowcap shim.
#
# Ordinary invocation: resolve the published selection, apply the driver's
# update-ownership environment and argv prefix, and exec the tool with the
# original arguments, streams, and status. A warm invocation touches no
# network, takes no lock, and runs no version probe. First use installs the
# checkout's seed under the maintenance lock. Intercepted lifecycle forms
# (bare `update` and friends) route to the management front; unsupported
# lifecycle forms are refused with its remedy.

set -euo pipefail

invoked="$(basename "${BASH_SOURCE[0]}")"
self="$(readlink -f "${BASH_SOURCE[0]}")"
dir="$(cd "$(dirname "${self}")/.." && pwd)"
GLOWCAP_TOOLS_FRONT="${dir}/bin/tools.sh"

# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
# shellcheck source=../lib/update-pins-deps.sh
source "${dir}/lib/update-pins-deps.sh"
glowcap_devcontainer_init "${dir}" checksums
glowcap_require_devcontainer "tools/wrapper"

# shellcheck source=lib/registry.sh
source "${dir}/tools/lib/registry.sh"
# shellcheck source=lib/lifecycle.sh
source "${dir}/tools/lib/lifecycle.sh"

tool="$(glowcap_tools_for_name "${invoked}")" || exit $?
# The driver file is selected by the registry: data, not a literal.
# shellcheck source=/dev/null
source "${dir}/tools/lib/${tool}.sh"

action="$(glowcap_tools_dispatch "${tool}" intercept "$@")"
case "${action}" in
    pass) ;;
    update)
        exec bash "${GLOWCAP_TOOLS_FRONT}" update "${tool}"
        ;;
    help)
        echo "${invoked}: update operations are managed by ${GLOWCAP_TOOLS_FRONT}" >&2
        echo "  (status, ensure, update, repair; the vendor updater is disabled in this container)" >&2
        exit 0
        ;;
    refuse:*)
        echo "${invoked}: ${action#refuse:}" >&2
        exit 64
        ;;
    *)
        echo "tools: unexpected intercept classification: ${action}" >&2
        exit 1
        ;;
esac

glowcap_tools_resolve_exec "${tool}" || exit $?
env_args=()
glowcap_tools_exec_env_lines "${tool}" "${GLOWCAP_TOOLS_SELECTED}" env_args
argv_prefix=()
while IFS= read -r word; do
    [[ -z "${word}" ]] || argv_prefix+=("${word}")
done < <(glowcap_tools_dispatch "${tool}" argv_prefix "${GLOWCAP_TOOLS_SELECTED}")

# `env --` keeps an argv prefix that starts with a dash (cursor's
# --disable-auto-update) the tool's argument, never env's option. The prefix
# precedes the user's arguments, so top-level options stay ahead of any
# subcommand.
exec env -- "${env_args[@]}" "${GLOWCAP_TOOLS_EXEC}" "${argv_prefix[@]}" "$@"
