#!/usr/bin/env bash
# shellcheck disable=SC2154
# Open one host tmux session holding a grid of pancake devcontainer shells:
# one column per worktree. A column is one full-height shell until its
# worktree's ignored .devcontainer/pane/panes.sh declares pane functions; the
# highest paneN it declares sets that column's row count.
#
#   bash .devcontainer/bin/enter-grid.sh                   columns: every registered worktree
#   bash .devcontainer/bin/enter-grid.sh main tree2        columns: only these
#   bash .devcontainer/bin/enter-grid.sh --session review  tmux: pancake-grid-review
#   bash .devcontainer/bin/enter-grid.sh --rebuild         rebuild every column's container
#   bash .devcontainer/bin/enter-grid.sh --cc | --no-cc    force or refuse control mode
#
# An iTerm2 client attaches in tmux control mode (-CC), so the grid renders
# as native iTerm2 splits; every other emulator attaches as an ordinary tmux
# client. --cc and --no-cc override that detection.
#
# Each column shares enter.sh's lifecycle: that worktree's own up.sh starts
# or reuses its container, whether the file still sits beside compose or has
# moved into bin/. Every pane in the column opens a shell in it. The pane
# runtime is this launcher's; it sources the worktree's panes.sh in
# each pane's container shell when that checkout has one.
# each pane's container shell, and the paneN function matching the pane's
# row runs as its startup command; .devcontainer/pane/panes.example.sh shows the
# shape. With --session NAME a panes-NAME.sh file is preferred when it
# exists. Splitting by percentage needs tmux 3.1 or newer.
#
# Every pane's shell stays on the host, in its worktree, with the container
# shell inside it, so `exit` ends the pane while `pancake_devcontainer_exit`
# steps out to the host and `pancake_devcontainer_enter` goes back in.
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

pancake_devcontainer_parse_launcher_args "enter-grid.sh" "${source_path}" "$@"

# Explicitly named worktrees are a contract: validate them, and refuse a
# duplicate, before anything else can fail.
worktree_count="${launcher_positional_count}"
for ((i = 0; i < worktree_count; i++)); do
    worktrees[i]="${launcher_positionals[i]}"
    pancake_devcontainer_validate_worktree_name "${worktrees[i]}" "worktree name"
    for ((j = 0; j < i; j++)); do
        if [[ "${worktrees[i]}" == "${worktrees[j]}" ]]; then
            echo "enter-grid.sh: worktree ${worktrees[i]} is listed more than once" >&2
            exit 2
        fi
    done
done
pancake_require_host "enter-grid.sh"
pancake_devcontainer_require_launcher_tools "enter-grid.sh"

launcher_checkout="$(dirname "${devcontainer_dir}")"
primary_checkout="$(pancake_devcontainer_primary_checkout "${launcher_checkout}")"

# With no columns named, every registered worktree is one. Unlike an
# explicitly named worktree, this inventory default is best-effort: a
# registered checkout that is missing on disk, has no up.sh, or sits
# outside the worktree grammar is skipped with a note instead of failing
# the grid. The resolve error is left on stderr so the skip names the
# reason instead of swallowing it.
if [[ ${worktree_count} -eq 0 ]]; then
    while IFS= read -r candidate; do
        if ! pancake_devcontainer_validate_worktree_name "${candidate}" "worktree name" 2>/dev/null; then
            echo "enter-grid.sh: skipping registered worktree ${candidate}: not a devcontainer worktree name" >&2
            continue
        fi
        if ! pancake_devcontainer_resolve_checkout "enter-grid.sh" \
            "${primary_checkout}" "${candidate}" >/dev/null; then
            echo "enter-grid.sh: skipping registered worktree ${candidate}" >&2
            continue
        fi
        worktrees[worktree_count]="${candidate}"
        worktree_count=$((worktree_count + 1))
    done < <(pancake_devcontainer_registered_worktrees "${primary_checkout}")
fi

for ((i = 0; i < worktree_count; i++)); do
    checkout="$(pancake_devcontainer_resolve_checkout "enter-grid.sh" "${primary_checkout}" "${worktrees[i]}")"
    checkouts[i]="${checkout}"

    # The worktree's panes file is that column's configuration: which file
    # this session reads, and how many rows the column gets. The ceiling
    # pairs with the virtual window the grid is built on: 12 rows of six
    # lines each fill its 72-line height.
    panes_names[i]="$(pancake_devcontainer_panes_name "${checkout}" "${launcher_session}")"
    rows="$(pancake_devcontainer_grid_rows "${checkout}/.devcontainer/pane/${panes_names[i]}")"
    if [[ "${rows}" -gt 12 ]]; then
        echo "enter-grid.sh: ${checkout}/.devcontainer/pane/${panes_names[i]} declares pane${rows}; a column holds at most 12 rows" >&2
        exit 1
    fi
    if [[ "${rows}" -eq 0 ]]; then
        rows=1
    fi
    grid_rows[i]="${rows}"
done

# The grid spans worktree containers, so its session takes the literal grid
# in the worktree slot of the shared naming scheme. The trailing colon on the
# window target qualifies the exact session, as in enter.sh.
session="$(pancake_devcontainer_tmux_session_name grid "${launcher_session}")"
session_target="=${session}"
window_target="${session_target}:"

for ((i = 0; i < worktree_count; i++)); do
    containers[i]="$(pancake_devcontainer_column_container "${checkouts[i]}" "${launcher_mode}")"
done

pancake_devcontainer_replace_dead_session "${session_target}" "${window_target}"

if ! tmux has-session -t "${session_target}" 2>/dev/null; then
    # Build the grid on a generous virtual size so every pane fits before a
    # client attaches; tmux resizes the window to the real client on attach.
    # A failed split or send must not leave a half-built grid for the next
    # run to find live and attach: tear the partial session down and let the
    # error stand.
    tmux new-session -d -s "${session}" -x 240 -y 72 -c "${checkouts[0]}"
    trap 'tmux kill-session -t "${session_target}" 2>/dev/null || true' ERR
    first_pane="$(tmux display-message -p -t "${window_target}" '#{pane_id}')"

    # Panes are addressed by id, never by number: numbering depends on the
    # host's pane-base-index and renumbers as splits land, so every split
    # names the pane it divides and reports the id of the pane it created.
    column_panes[0]="${first_pane}"
    for ((i = 1; i < worktree_count; i++)); do
        column_panes[i]="$(tmux split-window -h -P -F '#{pane_id}' \
            -t "${column_panes[i - 1]}" -c "${checkouts[i]}")"
    done
    tmux select-layout -t "${window_target}" even-horizontal

    for ((i = 0; i < worktree_count; i++)); do
        # Divide the column into this worktree's rows, evenly: each split
        # names the newest pane and takes the remaining share it is owed,
        # so three rows split at 66% then 50%.
        row_panes=("${column_panes[i]}")
        previous="${column_panes[i]}"
        for ((r = 2; r <= grid_rows[i]; r++)); do
            share=$(((grid_rows[i] - r + 1) * 100 / (grid_rows[i] - r + 2)))
            previous="$(tmux split-window -v -l "${share}%" -P -F '#{pane_id}' \
                -t "${previous}" -c "${checkouts[i]}")"
            row_panes+=("${previous}")
        done
        # Startup commands are the worktree's own ignored configuration, run
        # by the pane runtime inside the container: it initializes the shell,
        # sources the panes file, then runs this row's pane function when it
        # is defined, so the command runs in a fully initialized interactive
        # shell with no race against the shell's own startup.
        row=0
        for pane in "${row_panes[@]}"; do
            row=$((row + 1))
            pane_command="$(pancake_devcontainer_pane_shell_command \
                "${checkouts[i]}" "${worktrees[i]}" "${panes_names[i]}" "${row}")"
            tmux select-pane -t "${pane}" -T "${worktrees[i]}"
            tmux send-keys -t "${pane}" "${pane_command}" C-m
        done
    done
    trap - ERR

    if ! tmux has-session -t "${session_target}" 2>/dev/null; then
        echo "enter-grid.sh: tmux session ${session} exited immediately" >&2
        echo "enter-grid.sh: check: docker exec -it --user vscode ${containers[0]} /bin/zsh" >&2
        exit 1
    fi
    tmux select-pane -t "${first_pane}"
fi

pancake_devcontainer_attach_session "${session_target}" "${launcher_cc_mode}"
