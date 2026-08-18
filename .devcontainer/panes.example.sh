# shellcheck shell=bash
# enter-grid.sh starts each pane of this worktree's grid column through
# pane-rc.sh, which sources the worktree's ignored .devcontainer/panes.sh
# after ~/.bashrc. It is plain bash. Top-level lines run in every pane of
# the column, so an export here configures all of its shells. A paneN
# function runs as one pane's startup command, counted from the top, and
# the highest paneN declared at the start of a line sets the column's row
# count: without this file, or without pane functions, the column is one
# full-height shell. The functions stay defined in each pane's shell, so
# re-running one is its name or one up-arrow.
#
# With --session NAME, a .devcontainer/panes-NAME.sh file is preferred when
# it exists, so one worktree can carry different grids for different
# sessions. This annotated example is tracked; panes.sh and panes-*.sh stay
# local.

pane1() {
    claude
}

pane3() {
    zig build check
}
