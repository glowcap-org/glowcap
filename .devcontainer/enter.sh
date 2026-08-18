#!/usr/bin/env bash
# shellcheck disable=SC2154
# Open a host tmux session attached to one pancake worktree's devcontainer.
#
#   bash .devcontainer/enter.sh                 primary checkout (`main`)
#   bash .devcontainer/enter.sh tree1           linked worktree named tree1
#   bash .devcontainer/enter.sh --session review
#   bash .devcontainer/enter.sh tree1 --session review
#   bash .devcontainer/enter.sh --rebuild       rebuild and open `main`
#   bash .devcontainer/enter.sh tree1 --session review --rebuild
#   bash .devcontainer/enter.sh tree1 --no-cache
#   bash .devcontainer/enter.sh --cc | --no-cc  force or refuse control mode
#
# An iTerm2 client attaches in tmux control mode (-CC), so the session renders
# as a native iTerm2 window; every other emulator attaches as an ordinary tmux
# client. --cc and --no-cc override that detection.
#
# pancake is the CapTP CLI. This host launcher does not take that name.
set -euo pipefail

# Resolve the checked-out launcher through any number of symlinks. Git's common
# directory then identifies the primary checkout independently of where the
# repository or the invoking symlink lives on this host. This block runs before
# lib.sh exists to be sourced, so each launcher carries its own copy.
source_path="${BASH_SOURCE[0]}"
while [[ -L "${source_path}" ]]; do
    source_dir="$(cd -P "$(dirname "${source_path}")" && pwd)"
    source_path="$(readlink "${source_path}")"
    if [[ "${source_path}" != /* ]]; then
        source_path="${source_dir}/${source_path}"
    fi
done
source_dir="$(cd -P "$(dirname "${source_path}")" && pwd)"
# shellcheck source=launcher-lib.sh
source "${source_dir}/launcher-lib.sh"

pancake_devcontainer_parse_launcher_args "enter.sh" "${source_path}" "$@"
if [[ ${launcher_positional_count} -gt 1 ]]; then
    echo "enter.sh: specify at most one worktree" >&2
    exit 2
fi
worktree=main
if [[ ${launcher_positional_count} -eq 1 ]]; then
    worktree="${launcher_positionals[0]}"
fi
pancake_devcontainer_validate_worktree_name "${worktree}" "worktree name"
pancake_require_host "enter.sh"
pancake_devcontainer_require_launcher_tools "enter.sh"

launcher_checkout="$(dirname "${source_dir}")"
primary_checkout="$(pancake_devcontainer_primary_checkout "${launcher_checkout}")"
checkout="$(pancake_devcontainer_resolve_checkout "enter.sh" "${primary_checkout}" "${worktree}")"

session="$(pancake_devcontainer_tmux_session_name "${worktree}" "${launcher_session}")"
session_target="=${session}"
# Pane and window commands need the trailing colon to qualify the exact session
# target. Without it, tmux may interpret `=pancake-main` as a pane name.
window_target="${session_target}:"

pancake_devcontainer_up_checkout "${checkout}" "${launcher_mode}"
container_id="$(pancake_devcontainer_running_container "${checkout}")"

pancake_devcontainer_replace_dead_session "${session_target}" "${window_target}"

if ! tmux has-session -t "${session_target}" 2>/dev/null; then
    tmux new-session -d -s "${session}" -c "${checkout}"
    container_command="$(pancake_devcontainer_pane_shell_command "${container_id}")"
    tmux send-keys -t "${window_target}" "${container_command}" C-m
    if ! tmux has-session -t "${session_target}" 2>/dev/null; then
        echo "enter.sh: tmux session ${session} exited immediately" >&2
        echo "enter.sh: check: docker exec -it --user vscode ${container_id} /bin/bash" >&2
        exit 1
    fi
fi

pancake_devcontainer_attach_session "${session_target}" "${launcher_cc_mode}"
