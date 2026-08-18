# shellcheck shell=bash
# Shared helpers for the host tmux launchers, enter.sh and enter-grid.sh:
# each launcher fact has this one home so the two cannot drift apart. These
# run on the host, and assume the caller passed pancake_require_host. The
# base library is sourced here so a launcher sources exactly one file.
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# A grid column's row count comes from its worktree's panes file: the highest
# N among paneN() functions declared at the start of a line, an optional
# `function` keyword included. The scan is textual because the file is
# written for the container shell and must not execute on the host, so a
# paneN built dynamically at source time does not add a row. Prints 0 for a
# missing file or one declaring no pane functions; the caller owns the
# default and the ceiling.
pancake_devcontainer_grid_rows() {
    local file="$1" max=0 n
    if [[ ! -f "${file}" ]]; then
        printf '0\n'
        return 0
    fi
    while IFS= read -r n; do
        n=$((10#${n}))
        if [[ "${n}" -gt "${max}" ]]; then
            max="${n}"
        fi
    done < <(sed -nE 's/^(function[[:space:]]+)?pane([0-9]+)[[:space:]]*\(\).*/\2/p' "${file}")
    printf '%s\n' "${max}"
}

# iTerm2 draws a control-mode tmux client (tmux -CC) as native terminal
# splits. It declares itself in TERM_PROGRAM locally and, with its shell
# integration installed, in LC_TERMINAL across ssh. Any other emulator prints
# the control-mode protocol as text, so launchers treat this detection as a
# default only, behind explicit --cc / --no-cc overrides.
pancake_devcontainer_client_is_iterm2() {
    [[ "${TERM_PROGRAM:-}" == iTerm.app || "${LC_TERMINAL:-}" == iTerm2 ]]
}

# --- Host tmux launchers ----------------------------------------------------
# enter.sh and enter-grid.sh compose the helpers below; each launcher fact
# has this one home so the two cannot drift apart. These run on the host and
# assume the caller passed pancake_require_host.

# A launcher's header comment is its usage text: print from the line after
# the shebang to the first non-comment line, so editing the header cannot
# strand a line-number range. Shellcheck directive lines are tooling, not
# usage, and are skipped.
pancake_devcontainer_launcher_usage() {
    awk 'NR > 1 && !/^#/ { exit }
         NR > 1 && !/^# shellcheck/ { sub(/^# ?/, ""); print }' "$1"
}

# The one option grammar both launchers speak: --rebuild/--no-cache (the
# lifecycle mode), --cc/--no-cc (the attach mode), --session, and -h/--help
# printed from the resolved script path. Results land in launcher_mode,
# launcher_cc_mode, launcher_session, launcher_session_given, and the
# positional arguments in launcher_positionals under an explicit
# launcher_positional_count, so an empty set is never expanded (bash 3.2
# rejects that under `set -u`). Exits the process on a grammar error; this
# is a launcher front end, not a query helper. The launcher_* globals are
# consumed by the sourcing launchers, which per-file analysis cannot see.
# shellcheck disable=SC2034
pancake_devcontainer_parse_launcher_args() {
    local name="$1" script="$2" argument requested
    shift 2
    launcher_mode=up
    launcher_cc_mode=""
    launcher_session=""
    launcher_session_given=false
    launcher_positional_count=0
    while [[ $# -gt 0 ]]; do
        argument="$1"
        case "${argument}" in
            --rebuild | --no-cache)
                requested="${argument#--}"
                if [[ "${launcher_mode}" != up && "${launcher_mode}" != "${requested}" ]]; then
                    echo "${name}: --rebuild and --no-cache are mutually exclusive" >&2
                    exit 2
                fi
                launcher_mode="${requested}"
                ;;
            --cc | --no-cc)
                requested="${argument#--}"
                if [[ -n "${launcher_cc_mode}" && "${launcher_cc_mode}" != "${requested}" ]]; then
                    echo "${name}: --cc and --no-cc are mutually exclusive" >&2
                    exit 2
                fi
                launcher_cc_mode="${requested}"
                ;;
            --session | --session=*)
                if [[ "${launcher_session_given}" == true ]]; then
                    echo "${name}: specify --session at most once" >&2
                    exit 2
                fi
                if [[ "${argument}" == --session ]]; then
                    shift
                    if [[ $# -eq 0 || "$1" == -* ]]; then
                        echo "${name}: --session requires a designator" >&2
                        exit 2
                    fi
                    launcher_session="$1"
                else
                    launcher_session="${argument#--session=}"
                    if [[ -z "${launcher_session}" ]]; then
                        echo "${name}: --session requires a designator" >&2
                        exit 2
                    fi
                fi
                launcher_session_given=true
                ;;
            -h | --help)
                pancake_devcontainer_launcher_usage "${script}"
                exit 0
                ;;
            --*)
                echo "${name}: unknown option: ${argument}" >&2
                pancake_devcontainer_launcher_usage "${script}" >&2
                exit 2
                ;;
            *)
                launcher_positionals[launcher_positional_count]="${argument}"
                launcher_positional_count=$((launcher_positional_count + 1))
                ;;
        esac
        shift
    done
    if [[ "${launcher_session_given}" == true ]]; then
        pancake_devcontainer_validate_session_designator "${launcher_session}"
    fi
}

pancake_devcontainer_require_launcher_tools() {
    local name="$1" tool
    for tool in git docker tmux; do
        if ! command -v "${tool}" >/dev/null; then
            echo "${name}: ${tool} is not on PATH" >&2
            return 1
        fi
    done
}

# Resolve a worktree name to a checkout this launcher can enter: registered
# with Git, present on disk, and carrying an executable lifecycle entrypoint.
pancake_devcontainer_resolve_checkout() {
    local name="$1" primary="$2" worktree="$3" checkout
    checkout="$(pancake_devcontainer_checkout_for_worktree "${primary}" "${worktree}")" || return
    if [[ ! -d "${checkout}" ]]; then
        echo "${name}: checkout does not exist: ${checkout}" >&2
        return 1
    fi
    if [[ ! -x "${checkout}/.devcontainer/up.sh" ]]; then
        echo "${name}: checkout has no executable .devcontainer/up.sh: ${checkout}" >&2
        return 1
    fi
    printf '%s\n' "${checkout}"
}

# Every checkout Git registers for this repository, as launcher worktree
# names: the primary checkout is main, a linked worktree is its directory
# basename. The porcelain listing is the only authority on what exists;
# callers decide what to do with a name outside the devcontainer grammar.
pancake_devcontainer_registered_worktrees() {
    local primary="$1" line listing first=true path
    listing="$(git -C "${primary}" worktree list --porcelain)" || return 1
    while IFS= read -r line; do
        case "${line}" in
            worktree\ *)
                path="${line#worktree }"
                if [[ "${first}" == true ]]; then
                    first=false
                    printf 'main\n'
                else
                    printf '%s\n' "${path##*/}"
                fi
                ;;
        esac
    done <<< "${listing}"
}

# The checkout's devcontainer entrypoint is the lifecycle authority: it
# reuses a current container, starts or creates a missing one, and builds
# when the configuration requires it. Explicit rebuild modes pass through.
pancake_devcontainer_up_checkout() {
    local checkout="$1" mode="$2"
    case "${mode}" in
        rebuild) bash "${checkout}/.devcontainer/up.sh" --rebuild ;;
        no-cache) bash "${checkout}/.devcontainer/up.sh" --no-cache ;;
        *) bash "${checkout}/.devcontainer/up.sh" ;;
    esac
}

# The one shell command a pane runs: docker exec into the checkout's labeled
# container as the workspace user. With a row and panes name, the shell
# starts through pane-rc.sh, which runs that pane's configured startup
# command; without them it is a plain interactive shell.
pancake_devcontainer_pane_shell_command() {
    local container="$1" row="${2:-}" panes_name="${3:-}"
    if [[ -n "${row}" ]]; then
        printf 'exec docker exec -it --user vscode --workdir /workspaces/pancake -e PANCAKE_GRID_ROW=%d -e PANCAKE_GRID_PANES=%s %q /bin/bash --rcfile .devcontainer/pane-rc.sh\n' \
            "${row}" "${panes_name}" "${container}"
    else
        printf 'exec docker exec -it --user vscode --workdir /workspaces/pancake %q /bin/bash\n' \
            "${container}"
    fi
}

# A docker-exec pane normally takes its tmux session with it when it exits.
# Respect hosts configured to retain dead panes by replacing a fully dead
# session explicitly. Mixed live and dead panes belong to the user.
pancake_devcontainer_replace_dead_session() {
    local session_target="$1" window_target="$2" pane_states
    if tmux has-session -t "${session_target}" 2>/dev/null; then
        pane_states="$(tmux list-panes -s -t "${window_target}" -F '#{pane_dead}')"
        if [[ "${pane_states}" != *0* ]]; then
            tmux kill-session -t "${session_target}"
        fi
    fi
}

# Hand the terminal to a ready session. Inside an existing tmux client the
# attach mode is already decided, so the session is switched to as-is.
# Otherwise iTerm2 attaches in control mode unless a --cc/--no-cc flag chose.
pancake_devcontainer_attach_session() {
    local session_target="$1" cc_mode="$2"
    if [[ -n "${TMUX:-}" ]]; then
        exec tmux switch-client -t "${session_target}"
    fi
    if [[ -z "${cc_mode}" ]]; then
        if pancake_devcontainer_client_is_iterm2; then
            cc_mode=cc
        else
            cc_mode=no-cc
        fi
    fi
    if [[ "${cc_mode}" == cc ]]; then
        exec tmux -CC attach-session -t "${session_target}"
    fi
    exec tmux attach-session -t "${session_target}"
}
