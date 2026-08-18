#!/usr/bin/env bash
# shellcheck disable=SC2154
# Open one host tmux session holding a grid of pancake devcontainer shells:
# one column per worktree. A column is one full-height shell until its
# worktree's ignored .devcontainer/panes.sh declares pane functions; the
# highest paneN it declares sets that column's row count.
#
#   bash .devcontainer/enter-grid.sh                   columns: every registered worktree
#   bash .devcontainer/enter-grid.sh main tree2        columns: only these
#   bash .devcontainer/enter-grid.sh --session review  tmux: pancake-grid-review
#   bash .devcontainer/enter-grid.sh --rebuild         rebuild every column's container
#   bash .devcontainer/enter-grid.sh --cc | --no-cc    force or refuse control mode
#
# An iTerm2 client attaches in tmux control mode (-CC), so the grid renders
# as native iTerm2 splits; every other emulator attaches as an ordinary tmux
# client. --cc and --no-cc override that detection.
#
# Each column shares enter.sh's lifecycle: the worktree checkout's up.sh
# starts or reuses that worktree's container, then every pane in the column
# runs docker exec into it. pane-rc.sh sources the worktree's panes.sh in
# each pane's container shell, and the paneN function matching the pane's
# row runs as its startup command; .devcontainer/panes.example.sh shows the
# shape. With --session NAME a panes-NAME.sh file is preferred when it
# exists. Splitting by percentage needs tmux 3.1 or newer.
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

launcher_checkout="$(dirname "${source_dir}")"
primary_checkout="$(pancake_devcontainer_primary_checkout "${launcher_checkout}")"

# With no columns named, every registered worktree is one. Unlike an
# explicitly named worktree, this inventory default is best-effort: a
# registered checkout that is missing on disk or sits outside the worktree
# grammar is skipped with a note instead of failing the grid.
if [[ ${worktree_count} -eq 0 ]]; then
    while IFS= read -r candidate; do
        if ! pancake_devcontainer_validate_worktree_name "${candidate}" "worktree name" 2>/dev/null; then
            echo "enter-grid.sh: skipping registered worktree ${candidate}: not a devcontainer worktree name" >&2
            continue
        fi
        if [[ "${candidate}" != main ]]; then
            if ! candidate_path="$(pancake_devcontainer_checkout_for_worktree \
                "${primary_checkout}" "${candidate}" 2>/dev/null)" ||
                [[ ! -d "${candidate_path}" ]]; then
                echo "enter-grid.sh: skipping registered worktree ${candidate}: not an enterable checkout" >&2
                continue
            fi
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
    panes_names[i]=panes.sh
    if [[ -n "${launcher_session}" &&
        -f "${checkout}/.devcontainer/panes-${launcher_session}.sh" ]]; then
        panes_names[i]="panes-${launcher_session}.sh"
    fi
    rows="$(pancake_devcontainer_grid_rows "${checkout}/.devcontainer/${panes_names[i]}")"
    if [[ "${rows}" -gt 12 ]]; then
        echo "enter-grid.sh: ${checkout}/.devcontainer/${panes_names[i]} declares pane${rows}; a column holds at most 12 rows" >&2
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
    pancake_devcontainer_up_checkout "${checkouts[i]}" "${launcher_mode}"
    containers[i]="$(pancake_devcontainer_running_container "${checkouts[i]}")"
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
        # by pane-rc.sh inside the container: it sources ~/.bashrc, then the
        # panes file, then this row's pane function when it is defined, so
        # the command runs in a fully initialized interactive shell with no
        # race against the shell's own startup. A checkout without
        # pane-rc.sh (an older branch) gets a plain shell.
        row=0
        for pane in "${row_panes[@]}"; do
            row=$((row + 1))
            if [[ -f "${checkouts[i]}/.devcontainer/pane-rc.sh" ]]; then
                container_command="$(pancake_devcontainer_pane_shell_command \
                    "${containers[i]}" "${row}" "${panes_names[i]}")"
            else
                container_command="$(pancake_devcontainer_pane_shell_command "${containers[i]}")"
            fi
            tmux select-pane -t "${pane}" -T "${worktrees[i]}"
            tmux send-keys -t "${pane}" "${container_command}" C-m
        done
    done
    trap - ERR

    if ! tmux has-session -t "${session_target}" 2>/dev/null; then
        echo "enter-grid.sh: tmux session ${session} exited immediately" >&2
        echo "enter-grid.sh: check: docker exec -it --user vscode ${containers[0]} /bin/bash" >&2
        exit 1
    fi
    tmux select-pane -t "${first_pane}"
fi

pancake_devcontainer_attach_session "${session_target}" "${launcher_cc_mode}"
