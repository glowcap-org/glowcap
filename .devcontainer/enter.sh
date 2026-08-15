#!/usr/bin/env bash
# Open a host tmux session attached to one pancake worktree's devcontainer.
#
#   bash .devcontainer/enter.sh                 primary checkout (`main`)
#   bash .devcontainer/enter.sh tree1           linked worktree named tree1
#   bash .devcontainer/enter.sh --session review
#   bash .devcontainer/enter.sh tree1 --session review
#   bash .devcontainer/enter.sh --rebuild       rebuild and open `main`
#   bash .devcontainer/enter.sh tree1 --session review --rebuild
#   bash .devcontainer/enter.sh tree1 --no-cache
#
# pancake is the CapTP CLI. This host launcher does not take that name.
set -euo pipefail

# Resolve the checked-out launcher through any number of symlinks. Git's common
# directory then identifies the primary checkout independently of where the
# repository or the invoking symlink lives on this host.
source_path="${BASH_SOURCE[0]}"
while [[ -L "${source_path}" ]]; do
    source_dir="$(cd -P "$(dirname "${source_path}")" && pwd)"
    source_path="$(readlink "${source_path}")"
    if [[ "${source_path}" != /* ]]; then
        source_path="${source_dir}/${source_path}"
    fi
done
source_dir="$(cd -P "$(dirname "${source_path}")" && pwd)"
# shellcheck source=lib.sh
source "${source_dir}/lib.sh"

# The header comment above is the usage text: print it from the line after the
# shebang to the first non-comment line, so editing the header cannot strand a
# line-number range.
usage() {
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

worktree=main
worktree_given=false
session_designator=""
session_given=false
mode=up
while [[ $# -gt 0 ]]; do
    argument="$1"
    case "${argument}" in
        --rebuild | --no-cache)
            requested_mode="${argument#--}"
            if [[ "${mode}" != up && "${mode}" != "${requested_mode}" ]]; then
                echo "enter.sh: --rebuild and --no-cache are mutually exclusive" >&2
                exit 2
            fi
            mode="${requested_mode}"
            ;;
        --session | --session=*)
            if [[ "${session_given}" == true ]]; then
                echo "enter.sh: specify --session at most once" >&2
                exit 2
            fi
            if [[ "${argument}" == --session ]]; then
                shift
                if [[ $# -eq 0 || "$1" == -* ]]; then
                    echo "enter.sh: --session requires a designator" >&2
                    exit 2
                fi
                session_designator="$1"
            else
                session_designator="${argument#--session=}"
                if [[ -z "${session_designator}" ]]; then
                    echo "enter.sh: --session requires a designator" >&2
                    exit 2
                fi
            fi
            session_given=true
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --*)
            echo "enter.sh: unknown option: ${argument}" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ "${worktree_given}" == true ]]; then
                echo "enter.sh: specify at most one worktree" >&2
                exit 2
            fi
            worktree="${argument}"
            worktree_given=true
            ;;
    esac
    shift
done

pancake_devcontainer_validate_worktree_name "${worktree}" "worktree name"
if [[ "${session_given}" == true ]]; then
    pancake_devcontainer_validate_session_designator "${session_designator}"
fi
pancake_require_host "enter.sh"

command -v git >/dev/null || { echo "enter.sh: git is not on PATH" >&2; exit 1; }
command -v docker >/dev/null || { echo "enter.sh: docker is not on PATH" >&2; exit 1; }
command -v tmux >/dev/null || { echo "enter.sh: tmux is not on PATH" >&2; exit 1; }

launcher_checkout="$(dirname "${source_dir}")"
primary_checkout="$(pancake_devcontainer_primary_checkout "${launcher_checkout}")"
checkout="$(pancake_devcontainer_checkout_for_worktree "${primary_checkout}" "${worktree}")"

if [[ ! -d "${checkout}" ]]; then
    echo "enter.sh: checkout does not exist: ${checkout}" >&2
    exit 1
fi
if [[ ! -x "${checkout}/.devcontainer/up.sh" ]]; then
    echo "enter.sh: checkout has no executable .devcontainer/up.sh: ${checkout}" >&2
    exit 1
fi

session="$(pancake_devcontainer_tmux_session_name "${worktree}" "${session_designator}")"
session_target="=${session}"
# Pane and window commands need the trailing colon to qualify the exact session
# target. Without it, tmux may interpret `=pancake-main` as a pane name.
window_target="${session_target}:"

# The checkout's devcontainer entrypoint is the lifecycle authority: it reuses
# a current container, starts or creates a missing one, and builds when the
# configuration requires it. Explicit rebuild modes pass straight through.
# The three invocations are written out so bash 3.2 (macOS) never expands an
# empty array under `set -u`.
case "${mode}" in
    rebuild) bash "${checkout}/.devcontainer/up.sh" --rebuild ;;
    no-cache) bash "${checkout}/.devcontainer/up.sh" --no-cache ;;
    up) bash "${checkout}/.devcontainer/up.sh" ;;
esac
container_id="$(pancake_devcontainer_running_container "${checkout}")"

# A docker-exec pane normally takes its tmux session with it when it exits.
# Respect hosts configured to retain dead panes by replacing a fully dead
# session explicitly. Mixed live and dead panes belong to the user.
if tmux has-session -t "${session_target}" 2>/dev/null; then
    pane_states="$(tmux list-panes -s -t "${window_target}" -F '#{pane_dead}')"
    if [[ "${pane_states}" != *0* ]]; then
        tmux kill-session -t "${session_target}"
    fi
fi

if ! tmux has-session -t "${session_target}" 2>/dev/null; then
    tmux new-session -d -s "${session}" -c "${checkout}"
    printf -v container_command \
        'exec docker exec -it --user vscode --workdir /workspaces/pancake %q /bin/bash' \
        "${container_id}"
    tmux send-keys -t "${window_target}" "${container_command}" C-m
    if ! tmux has-session -t "${session_target}" 2>/dev/null; then
        echo "enter.sh: tmux session ${session} exited immediately" >&2
        echo "enter.sh: check: docker exec -it --user vscode ${container_id} /bin/bash" >&2
        exit 1
    fi
fi

if [[ -n "${TMUX:-}" ]]; then
    exec tmux switch-client -t "${session_target}"
fi
exec tmux attach-session -t "${session_target}"
