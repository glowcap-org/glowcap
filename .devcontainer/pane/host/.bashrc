# shellcheck shell=bash
# Interactive rc for one pancake tmux pane's shell on the host: the host half
# of the pane runtime, whose container half is ../container/.zshrc. bin/enter.sh
# and bin/enter-grid.sh name this file on every pane's shell command, and it
# sources your own ~/.bashrc first, so the shell stays yours with the runtime
# added to it.
#
# Each side of the boundary is named for the shell that reads it. The host is
# bash, which finds an rc by path and needs nothing else. The container is
# zsh, the shell the image configures for the workspace user, and zsh finds
# an rc only by directory, through ZDOTDIR, which is why that side is a
# directory holding one file.
#
# The pane's shell stays here, on the host, in this worktree's checkout, and
# the container shell runs as its child. That is what makes leaving the
# container something other than losing the pane: pancake_devcontainer_exit
# inside the container comes back to this shell, and
# pancake_devcontainer_enter goes back in. Plain exit still ends the pane,
# because the shell it ends is the one this file entered from.
#
# What it leaves behind is two verbs, a few variables, and a marker on the
# prompt. It reads none of the shell library beside it: everything it needs
# from the host is one answer, which this launcher's bin/container-id.sh
# gives it for the checkout it was asked to wrap.
#
# This file is an rcfile for an interactive shell, so it must not set -e or
# -u: either would outlive startup and poison the session it configures.
# shellcheck source=/dev/null
[[ -f ~/.bashrc ]] && source ~/.bashrc

# This file is <launcher>/.devcontainer/pane/host/.bashrc. The checkout it
# wraps is handed in so one launcher can open a column whose `.devcontainer/`
# is older; without that, the checkout is the tree this file lives in.
pancake_tmux_launcher_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pancake_tmux_checkout="${PANCAKE_TMUX_CHECKOUT:-$(cd -P "${pancake_tmux_launcher_root}/.." && pwd)}"

# Where the workspace is mounted inside the container. Three things the
# runtime hands across the boundary are built from it, so it is written once.
pancake_tmux_workspace=/workspaces/pancake

# The status the container shell exits with to mean "leave the container,
# keep this pane". It is declared here, where the comparison happens, and
# handed to the container shell in its environment, so the two halves of the
# runtime cannot disagree about it. It sits below 125 so it lands in the band
# this file reads as "the shell ended on its own terms", and away from the
# statuses a shell reaches for by itself.
PANCAKE_TMUX_DETACH_STATUS=89

# This shell is the pane's host side. Naming the way out of the container
# from outside it is worth an answer rather than a "command not found".
pancake_devcontainer_exit() {
    echo "pancake_devcontainer_exit: this shell is already on the host; exit ends the pane, pancake_devcontainer_enter opens the container" >&2
    return 1
}

# Open this worktree's container shell as a child of this one, and decide what
# the pane does when that shell ends. With --bare the pane's startup command
# stays behind, for a look around that must not restart what the pane runs.
# shellcheck disable=SC2120
pancake_devcontainer_enter() {
    local bare=false container pane_status
    local -a shell_argv
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bare) bare=true ;;
            *)
                echo "pancake_devcontainer_enter: unknown option: $1" >&2
                return 2
                ;;
        esac
        shift
    done
    # Which container this checkout has, and starting it when it is down, are
    # that script's contract rather than this shell's. A container stopped or
    # rebuilt since the pane opened comes back from the pane that wants it,
    # instead of sending the reader to another window for it. The lookup is
    # this launcher's: the column checkout may still keep `up.sh` beside
    # compose, or have no `bin/container-id.sh` of its own.
    container="$(bash "${pancake_tmux_launcher_root}/bin/container-id.sh" "${pancake_tmux_checkout}")" || return 1
    shell_argv=(docker exec -it --user vscode --workdir "${pancake_tmux_workspace}")
    if [[ -f "${pancake_tmux_checkout}/.devcontainer/pane/container/.zshrc" ]]; then
        shell_argv+=(-e "ZDOTDIR=${pancake_tmux_workspace}/.devcontainer/pane/container")
        shell_argv+=(-e "PANCAKE_TMUX_DETACH_STATUS=${PANCAKE_TMUX_DETACH_STATUS}")
        shell_argv+=(-e "PANCAKE_TMUX_PANES_FILE=${pancake_tmux_workspace}/.devcontainer/pane/${PANCAKE_TMUX_PANES_NAME:-panes.sh}")
        if [[ "${bare}" == false && -n "${PANCAKE_TMUX_ROW:-}" ]]; then
            shell_argv+=(-e "PANCAKE_TMUX_ROW=${PANCAKE_TMUX_ROW}")
        fi
    fi
    shell_argv+=("${container}" /bin/zsh)
    "${shell_argv[@]}"
    pane_status=$?
    if [[ "${pane_status}" -eq "${PANCAKE_TMUX_DETACH_STATUS}" ]]; then
        printf 'pancake: on the host in %s. pancake_devcontainer_enter returns; exit ends this pane.\n' \
            "${pancake_tmux_checkout}"
        return 0
    fi
    # Below 125 the shell ended on its own terms, by exit or by the status a
    # bare exit carried out of the last command, and the pane goes with it
    # exactly as it did when the pane ran docker exec itself. From 125 up,
    # docker could not run the shell or a signal ended it, so the pane stays
    # and says so: a container rebuilt from another window is re-entered from
    # right here.
    if [[ "${pane_status}" -ge 125 ]]; then
        printf 'pancake: the container shell ended with status %d. This pane is still here; pancake_devcontainer_enter returns.\n' \
            "${pane_status}" >&2
        return "${pane_status}"
    fi
    exit "${pane_status}"
}

# The prompt says which side of the container this shell is on. It is applied
# before each prompt rather than once, because a prompt that rebuilds itself
# from PROMPT_COMMAND would otherwise paint the marker away on the first
# command. Whatever your own rc set stands behind the marker; the rest of the
# prompt is yours.
pancake_tmux_prompt_mark="(host ${PANCAKE_TMUX_WORKTREE:-${pancake_tmux_checkout##*/}}) "
pancake_tmux_mark_prompt() {
    [[ "${PS1}" == "${pancake_tmux_prompt_mark}"* ]] ||
        PS1="${pancake_tmux_prompt_mark}${PS1}"
}
PROMPT_COMMAND="pancake_tmux_mark_prompt${PROMPT_COMMAND:+; ${PROMPT_COMMAND}}"

if ! pancake_devcontainer_enter; then
    printf 'pancake: on the host in %s. pancake_devcontainer_enter tries again.\n' \
        "${pancake_tmux_checkout}" >&2
fi
