# Interactive rc for one glowcap tmux pane's shell inside the container: the
# container half of the pane runtime, whose host half is ../host/.bashrc. That
# file names this directory in ZDOTDIR on its docker exec command line, which
# is how zsh is told to read this file in place of the workspace user's own
# ~/.zshrc. That one is sourced first, so the shell stays the one the image
# configured, with the runtime added to it.
#
# It then sources this worktree's ignored pane configuration, the panes file
# the host half named in GLOWCAP_TMUX_PANES_FILE: plain shell whose top level
# runs in every pane, and whose pane1, pane2, or pane3 function, when
# defined, runs as this pane's startup command. GLOWCAP_TMUX_ROW says which
# pane this is, and a pane without one is a plain shell with those functions
# in hand. The function stays defined and joins shell history, so after it
# exits, re-running it is its name or one up-arrow.
#
# exit ends the pane, as it always has. glowcap_devcontainer_exit leaves the
# container and keeps it: the host shell that opened this one is waiting in
# the worktree, and glowcap_devcontainer_enter there comes back.
#
# This file is an rcfile for an interactive shell, so it must not set -e or
# -u: either would outlive startup and poison the session it configures.
[[ -f ~/.zshenv ]] && source ~/.zshenv
[[ -f ~/.zshrc ]] && source ~/.zshrc

# A nested shell is an ordinary shell: it is not this pane, it has no host
# shell of its own waiting, and it must not run this pane's startup command a
# second time. Dropping ZDOTDIR is what keeps the runtime to the one shell
# the pane opened.
unset ZDOTDIR

# This shell is the pane's container side. Naming the way in from inside is
# worth an answer rather than a "command not found".
glowcap_devcontainer_enter() {
    print -u2 "glowcap_devcontainer_enter: this shell is already inside the devcontainer"
    return 1
}

# Leave the container without ending the pane. The status is the runtime's
# one wire between the two shells, declared by the host half and handed here,
# so a shell that arrived by some other route says so rather than inventing a
# host shell that is not waiting for it.
glowcap_devcontainer_exit() {
    if [[ -z "${GLOWCAP_TMUX_DETACH_STATUS:-}" ]]; then
        print -u2 "glowcap_devcontainer_exit: this shell was not opened by a glowcap tmux pane, so no host shell is waiting for it"
        return 1
    fi
    exit "${GLOWCAP_TMUX_DETACH_STATUS}"
}

if [[ -f "${GLOWCAP_TMUX_PANES_FILE:-}" ]]; then
    source "${GLOWCAP_TMUX_PANES_FILE}"
    if [[ -n "${GLOWCAP_TMUX_ROW:-}" ]] &&
        (( ${+functions[pane${GLOWCAP_TMUX_ROW}]} )); then
        print -s "pane${GLOWCAP_TMUX_ROW}"
        "pane${GLOWCAP_TMUX_ROW}"
    fi
fi
