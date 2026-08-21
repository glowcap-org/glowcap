# shellcheck shell=bash
# The name grammars this directory speaks, and nothing else.
#
# A worktree name, a tmux session designator, and a Docker network name each
# reach several scripts, and each is refused in exactly one place so the
# launchers, the checkout configuration, and the checks cannot drift into
# three slightly different ideas of a legal name.

# Shared worktree-name grammar: lowercase letters and digits, starts with a
# letter, at most 12 characters. The .env reader and enter.sh both use this.
pancake_devcontainer_validate_worktree_name() {
    local value="$1"
    local what="${2:-PANCAKE_WORKTREE}"
    case "${value}" in
        [a-z]* ) ;;
        *)
            echo "devcontainer: ${what} must start with a lowercase letter" >&2
            return 1
            ;;
    esac
    case "${value}" in
        *[!a-z0-9]* )
            echo "devcontainer: ${what} may contain only lowercase letters and digits" >&2
            return 1
            ;;
    esac
    if [[ ${#value} -gt 12 ]]; then
        echo "devcontainer: ${what} must be at most 12 characters" >&2
        return 1
    fi
}

# A tmux session designator is a human-facing suffix, not container identity.
# Keep it target-safe and readable: tmux gives ':' and '.' special meaning,
# while a compact lowercase label remains unambiguous in session listings.
pancake_devcontainer_validate_session_designator() {
    local value="$1"
    case "${value}" in
        [a-z]* ) ;;
        *)
            echo "devcontainer: session designator must start with a lowercase letter" >&2
            return 1
            ;;
    esac
    case "${value}" in
        *[!a-z0-9-]* )
            echo "devcontainer: session designator may contain only lowercase letters, digits, and hyphens" >&2
            return 1
            ;;
    esac
    case "${value}" in
        *[a-z0-9] ) ;;
        *)
            echo "devcontainer: session designator must end with a lowercase letter or digit" >&2
            return 1
            ;;
    esac
    if [[ ${#value} -gt 24 ]]; then
        echo "devcontainer: session designator must be at most 24 characters" >&2
        return 1
    fi
}

# The default deliberately preserves the container-shaped session name used by
# existing launchers. An explicit designator creates another tmux session while
# retaining the worktree container as the shared execution identity.
pancake_devcontainer_tmux_session_name() {
    local worktree="$1" designator="${2:-}"
    pancake_devcontainer_validate_worktree_name "${worktree}" "worktree name" || return
    if [[ -n "${designator}" ]]; then
        pancake_devcontainer_validate_session_designator "${designator}" || return
        printf 'pancake-%s-%s\n' "${worktree}" "${designator}"
    else
        printf 'pancake-%s\n' "${worktree}"
    fi
}

pancake_devcontainer_validate_network_name() {
    local value="$1"
    local what="${2:-Docker network name}"
    case "${value}" in
        [A-Za-z0-9]* ) ;;
        *)
            echo "devcontainer: ${what} must start with a letter or digit" >&2
            return 1
            ;;
    esac
    case "${value}" in
        *[!A-Za-z0-9_.-]* )
            echo "devcontainer: ${what} may contain only letters, digits, dots, underscores, and hyphens" >&2
            return 1
            ;;
    esac
    if [[ ${#value} -gt 63 ]]; then
        echo "devcontainer: ${what} must be at most 63 characters" >&2
        return 1
    fi
}
