#!/usr/bin/env bash
# shellcheck disable=SC2154
# Open a host tmux session attached to one glowcap worktree's devcontainer.
#
#   bash .devcontainer/bin/enter.sh                 primary checkout (`main`)
#   bash .devcontainer/bin/enter.sh tree1           linked worktree named tree1
#   bash .devcontainer/bin/enter.sh --session review
#   bash .devcontainer/bin/enter.sh tree1 --session review
#   bash .devcontainer/bin/enter.sh --rebuild       rebuild and open `main`
#   bash .devcontainer/bin/enter.sh tree1 --session review --rebuild
#   bash .devcontainer/bin/enter.sh tree1 --no-cache
#   bash .devcontainer/bin/enter.sh --cc | --no-cc  force or refuse control mode
#
# An iTerm2 client attaches in tmux control mode (-CC), so the session renders
# as a native iTerm2 window; every other emulator attaches as an ordinary tmux
# client. --cc and --no-cc override that detection.
#
# The pane's shell stays on the host, in the worktree, and the container shell
# runs inside it. So `exit` ends the pane as it always has, while
# `glowcap_devcontainer_exit` steps out of the container and leaves you on the
# host in that same worktree, where `glowcap_devcontainer_enter` goes back in.
#
# glowcap is the CapTP CLI. This host launcher does not take that name.
set -euo pipefail

# Resolve the checked-out launcher through any number of symlinks. Git's common
# directory then identifies the primary checkout independently of where the
# repository or the invoking symlink lives on this host. This block runs before
# the library exists to be sourced, so each launcher carries its own copy.
source_path="${BASH_SOURCE[0]}"
while [[ -L "${source_path}" ]]; do
    source_dir="$(cd -P "$(dirname "${source_path}")" && pwd)"
    source_path="$(readlink "${source_path}")"
    if [[ "${source_path}" != /* ]]; then
        source_path="${source_dir}/${source_path}"
    fi
done
source_dir="$(cd -P "$(dirname "${source_path}")" && pwd)"
devcontainer_dir="$(dirname "${source_dir}")"
# shellcheck source=../lib/launcher.sh
source "${devcontainer_dir}/lib/launcher.sh"

glowcap_devcontainer_parse_launcher_args "enter.sh" "${source_path}" "$@"
if [[ ${launcher_positional_count} -gt 1 ]]; then
    echo "enter.sh: specify at most one worktree" >&2
    exit 2
fi
worktree=main
if [[ ${launcher_positional_count} -eq 1 ]]; then
    worktree="${launcher_positionals[0]}"
fi
glowcap_devcontainer_validate_worktree_name "${worktree}" "worktree name"
glowcap_require_host "enter.sh"
glowcap_devcontainer_require_launcher_tools "enter.sh"

launcher_checkout="$(dirname "${devcontainer_dir}")"
primary_checkout="$(glowcap_devcontainer_primary_checkout "${launcher_checkout}")"
checkout="$(glowcap_devcontainer_resolve_checkout "enter.sh" "${primary_checkout}" "${worktree}")"

session="$(glowcap_devcontainer_tmux_session_name "${worktree}" "${launcher_session}")"
session_target="=${session}"
# Pane and window commands need the trailing colon to qualify the exact session
# target. Without it, tmux may interpret `=glowcap-main` as a pane name.
window_target="${session_target}:"

container_id="$(glowcap_devcontainer_column_container "${checkout}" "${launcher_mode}")"

glowcap_devcontainer_replace_dead_session "${session_target}" "${window_target}"

if ! tmux has-session -t "${session_target}" 2>/dev/null; then
    tmux new-session -d -s "${session}" -c "${checkout}"
    # No row: a session opened on its own is a plain container shell, with
    # this worktree's pane functions defined and none of them run, so naming
    # one at the prompt is how it starts.
    panes_name="$(glowcap_devcontainer_panes_name "${checkout}" "${launcher_session}")"
    pane_command="$(glowcap_devcontainer_pane_shell_command \
        "${checkout}" "${worktree}" "${panes_name}")"
    tmux send-keys -t "${window_target}" "${pane_command}" C-m
    if ! tmux has-session -t "${session_target}" 2>/dev/null; then
        echo "enter.sh: tmux session ${session} exited immediately" >&2
        echo "enter.sh: check: docker exec -it --user vscode ${container_id} /bin/zsh" >&2
        exit 1
    fi
fi

glowcap_devcontainer_attach_session "${session_target}" "${launcher_cc_mode}"
