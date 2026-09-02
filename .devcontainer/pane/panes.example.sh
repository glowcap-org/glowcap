# shellcheck shell=bash
# The pane runtime sources this worktree's ignored .devcontainer/pane/panes.sh in
# every pane's container shell, after that shell's own ~/.zshrc. Top-level
# lines run in every pane, so an export here configures all of them. A paneN
# function runs as one pane's startup command, counted from the top of that
# worktree's grid column, and the highest paneN declared at the start of a
# line sets the column's row count: without this file, or without pane
# functions, the column is one full-height shell. The functions stay defined
# in each pane's shell, so re-running one is its name or one up-arrow, and a
# session opened by enter.sh has them all defined with none of them running.
#
# The container shell is zsh, so keep this file to the syntax both it and
# bash read: the launchers scan it on the host for its pane functions, and
# scanning is all they do with it.
#
# Stepping out of the container with glowcap_devcontainer_exit and back in
# with glowcap_devcontainer_enter runs this pane's function again, which is
# how a pane restarts what it runs. glowcap_devcontainer_enter --bare skips
# it.
#
# With --session NAME, a .devcontainer/pane/panes-NAME.sh file is preferred when
# it exists, so one worktree can carry different grids for different
# sessions. This annotated example is tracked; panes.sh and panes-*.sh stay
# local.

pane1() {
    claude
}

pane3() {
    zig build check
}
