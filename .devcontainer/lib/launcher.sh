# shellcheck shell=bash
# Shared helpers for the host tmux launchers, enter.sh and enter-grid.sh:
# each launcher fact has this one home so the two cannot drift apart. These
# run on the host, and assume the caller passed glowcap_require_host. The
# base library is sourced here so a launcher sources exactly one file.
# shellcheck source=mod.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mod.sh"

# A grid column's row count comes from its worktree's panes file: the highest
# N among paneN() functions declared at the start of a line, an optional
# `function` keyword included. The scan is textual because the file is
# written for the container shell and must not execute on the host, so a
# paneN built dynamically at source time does not add a row. Prints 0 for a
# missing file or one declaring no pane functions; the caller owns the
# default and the ceiling.
glowcap_devcontainer_grid_rows() {
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
glowcap_devcontainer_client_is_iterm2() {
    [[ "${TERM_PROGRAM:-}" == iTerm.app || "${LC_TERMINAL:-}" == iTerm2 ]]
}

# A launcher's header comment is its usage text: print from the line after
# the shebang to the first non-comment line, so editing the header cannot
# strand a line-number range. Shellcheck directive lines are tooling, not
# usage, and are skipped.
glowcap_devcontainer_launcher_usage() {
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
glowcap_devcontainer_parse_launcher_args() {
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
                glowcap_devcontainer_launcher_usage "${script}"
                exit 0
                ;;
            --*)
                echo "${name}: unknown option: ${argument}" >&2
                glowcap_devcontainer_launcher_usage "${script}" >&2
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
        glowcap_devcontainer_validate_session_designator "${launcher_session}"
    fi
}

glowcap_devcontainer_require_launcher_tools() {
    local name="$1" tool
    for tool in git docker tmux; do
        if ! command -v "${tool}" >/dev/null; then
            echo "${name}: ${tool} is not on PATH" >&2
            return 1
        fi
    done
}

# Resolve a worktree name to a checkout this launcher can enter: registered
# with Git, present on disk, and carrying a lifecycle entry point. Worktrees
# sit on different branches, so that entry point may still be `up.sh` beside
# compose rather than `bin/up.sh`. The pane runtime comes from this launcher,
# not from the column.
glowcap_devcontainer_resolve_checkout() {
    local name="$1" primary="$2" worktree="$3" checkout
    checkout="$(glowcap_devcontainer_checkout_for_worktree "${primary}" "${worktree}")" || return
    if [[ ! -d "${checkout}" ]]; then
        echo "${name}: checkout does not exist: ${checkout}" >&2
        return 1
    fi
    if ! glowcap_devcontainer_checkout_entry "${checkout}" up.sh >/dev/null; then
        echo "${name}: checkout has no executable up.sh: ${checkout}" >&2
        return 1
    fi
    printf '%s\n' "${checkout}"
}

# Every checkout Git registers for this repository, as launcher worktree
# names: the primary checkout is main, a linked worktree is its directory
# basename. The porcelain listing is the only authority on what exists;
# callers decide what to do with a name outside the devcontainer grammar.
glowcap_devcontainer_registered_worktrees() {
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

# Bring up a column's container and report its id, by running this
# launcher's container-id.sh against that checkout. The column may still keep
# `up.sh` beside compose; this tree's lookup is what finds it. The lifecycle
# mode passes straight through as that script's option.
glowcap_devcontainer_column_container() {
    local checkout="$1" mode="$2" launcher_root
    launcher_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    bash "${launcher_root}/bin/container-id.sh" "--${mode}" "${checkout}"
}

# The panes file a session reads in a checkout: that worktree's panes.sh, or
# the panes-<designator>.sh variant when --session named one and the checkout
# carries it. Both launchers ask, so a worktree's session variants behave the
# same whether it is opened alone or as one column of a grid.
glowcap_devcontainer_panes_name() {
    local checkout="$1" session="${2:-}" panes_name=panes.sh
    if [[ -n "${session}" && -f "${checkout}/.devcontainer/pane/panes-${session}.sh" ]]; then
        panes_name="panes-${session}.sh"
    fi
    printf '%s\n' "${panes_name}"
}

# The one shell command a pane runs: this launcher's pane runtime, as the
# pane's shell on the host, in the checkout tmux already made the pane's
# directory. The column checkout is handed in so a grid can wrap a worktree
# whose own `.devcontainer/` has not yet grown the pane runtime. Entering
# the container is the runtime's job from there, which is what leaves the
# pane a host shell to come back to. A row makes the pane run that row's
# startup command; a pane without one is a plain container shell.
# The assignments are a validated worktree name, a file name from this
# directory, a checkout path, and a row number, so they cross into the
# pane's shell as themselves; printf %q quotes a host path that may contain
# spaces.
glowcap_devcontainer_pane_shell_command() {
    local checkout="$1" worktree="$2" panes_name="$3" row="${4:-}" launcher_root
    launcher_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [[ -n "${row}" ]]; then
        printf 'exec env GLOWCAP_TMUX_WORKTREE=%q GLOWCAP_TMUX_PANES_NAME=%q GLOWCAP_TMUX_CHECKOUT=%q GLOWCAP_TMUX_ROW=%q bash --rcfile %q -i\n' \
            "${worktree}" "${panes_name}" "${checkout}" "${row}" \
            "${launcher_root}/pane/host/.bashrc"
        return 0
    fi
    printf 'exec env GLOWCAP_TMUX_WORKTREE=%q GLOWCAP_TMUX_PANES_NAME=%q GLOWCAP_TMUX_CHECKOUT=%q bash --rcfile %q -i\n' \
        "${worktree}" "${panes_name}" "${checkout}" \
        "${launcher_root}/pane/host/.bashrc"
}

# A docker-exec pane normally takes its tmux session with it when it exits.
# Respect hosts configured to retain dead panes by replacing a fully dead
# session explicitly. Mixed live and dead panes belong to the user.
glowcap_devcontainer_replace_dead_session() {
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
glowcap_devcontainer_attach_session() {
    local session_target="$1" cc_mode="$2"
    if [[ -n "${TMUX:-}" ]]; then
        exec tmux switch-client -t "${session_target}"
    fi
    if [[ -z "${cc_mode}" ]]; then
        if glowcap_devcontainer_client_is_iterm2; then
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
