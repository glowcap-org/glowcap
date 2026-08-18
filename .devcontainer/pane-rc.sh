# shellcheck shell=bash
# Interactive rc for one enter-grid.sh grid pane, run inside the container in
# place of ~/.bashrc, which it sources first. It then sources the worktree's
# ignored pane configuration (.devcontainer/panes.sh, or the variant
# enter-grid.sh named in PANCAKE_GRID_PANES): plain bash whose top level runs
# in every pane of the column, and whose pane1, pane2, or pane3 function,
# when defined, runs as this pane's startup command — PANCAKE_GRID_ROW says
# which pane this is. The function stays defined and joins shell history, so
# after it exits, re-running it is its name or one up-arrow.
#
# This file is an rcfile for an interactive shell, so it must not set -e or
# -u: either would outlive startup and poison the session it configures.
# shellcheck source=/dev/null
[[ -f ~/.bashrc ]] && source ~/.bashrc

pancake_grid_panes_file=".devcontainer/${PANCAKE_GRID_PANES:-panes.sh}"
if [[ -f "${pancake_grid_panes_file}" ]]; then
    # shellcheck source=/dev/null
    source "${pancake_grid_panes_file}"
    if [[ -n "${PANCAKE_GRID_ROW:-}" ]] &&
        declare -F "pane${PANCAKE_GRID_ROW}" >/dev/null; then
        history -s "pane${PANCAKE_GRID_ROW}"
        "pane${PANCAKE_GRID_ROW}"
    fi
fi
unset pancake_grid_panes_file
