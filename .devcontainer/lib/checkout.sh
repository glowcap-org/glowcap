# shellcheck shell=bash
# Which checkout is which, according to Git.
#
# The primary checkout and every linked worktree are found through Git's own
# worktree listing and common directory, never through a host path written
# down somewhere, so these answers hold wherever the repository lives and
# whichever checkout is asking.

glowcap_devcontainer_worktree_kind() {
    local checkout="$1" git_dir common_dir
    git_dir="$(git -C "${checkout}" rev-parse --path-format=absolute --git-dir)" || return 1
    common_dir="$(git -C "${checkout}" rev-parse --path-format=absolute --git-common-dir)" || return 1
    if [[ "${git_dir}" == "${common_dir}" ]]; then
        printf '%s\n' primary
    else
        printf '%s\n' linked
    fi
}

# Read the checkout-local identity from Compose's ignored .env file.
glowcap_devcontainer_worktree_name() {
    local root="$1" value
    value="$(glowcap_devcontainer_env_value "${root}" GLOWCAP_WORKTREE)"
    if [[ -z "${value}" ]]; then
        echo "devcontainer: GLOWCAP_WORKTREE is missing from ${root}/.env" >&2
        echo "devcontainer: run: bash .devcontainer/bin/configure.sh" >&2
        return 1
    fi
    glowcap_devcontainer_validate_worktree_name "${value}" || return
    printf '%s\n' "${value}"
}

glowcap_devcontainer_primary_checkout() {
    local checkout="$1" line listing
    listing="$(git -C "${checkout}" worktree list --porcelain)" || return 1
    while IFS= read -r line; do
        case "${line}" in
            worktree\ *)
                printf '%s\n' "${line#worktree }"
                return 0
                ;;
        esac
    done <<< "${listing}"
    echo "devcontainer: Git did not report a primary checkout for ${checkout}" >&2
    return 1
}

# `main` is the primary checkout that owns the common Git directory. Any other
# name is a linked worktree whose directory basename is that name. Git's
# registered worktree list is the only authority on where it lives.
glowcap_devcontainer_checkout_for_worktree() {
    local primary="$1" name="$2" path listed="" line listing
    if [[ "${name}" == main ]]; then
        printf '%s\n' "${primary}"
        return 0
    fi
    listing="$(git -C "${primary}" worktree list --porcelain)" || return 1
    while IFS= read -r line; do
        case "${line}" in
            worktree\ *)
                path="${line#worktree }"
                [[ "${path}" == "${primary}" ]] && continue
                if [[ "${path##*/}" == "${name}" ]]; then
                    if [[ -n "${listed}" ]]; then
                        echo "devcontainer: multiple worktrees are named ${name}" >&2
                        return 1
                    fi
                    listed="${path}"
                fi
                ;;
        esac
    done <<< "${listing}"
    if [[ -n "${listed}" ]]; then
        printf '%s\n' "${listed}"
        return 0
    fi
    echo "devcontainer: Git has no linked worktree named ${name}" >&2
    return 1
}

# The ignored value is useful only if the worktree and container identities
# agree. The primary checkout may live in a repository directory named
# `glowcap`; linked worktrees use their designator as the directory basename.
# Branch names are independent.
glowcap_devcontainer_validate_worktree() {
    local root="$1" name="$2" checkout kind
    checkout="$(basename "$(cd "${root}/.." && pwd -P)")"
    kind="$(glowcap_devcontainer_worktree_kind "${root}/..")" || return
    if [[ "${kind}" == primary ]]; then
        if [[ "${name}" != main ]]; then
            echo "devcontainer: the primary checkout must use GLOWCAP_WORKTREE=main, not ${name}" >&2
            return 1
        fi
    elif [[ "${name}" == main ]]; then
        echo "devcontainer: a linked worktree may not use GLOWCAP_WORKTREE=main" >&2
        return 1
    elif [[ "${checkout}" != "${name}" ]]; then
        echo "devcontainer: GLOWCAP_WORKTREE=${name}, but the worktree directory is ${checkout}" >&2
        echo "devcontainer: use the same short name for the worktree and container" >&2
        return 1
    fi
}

# Submodule repositories need one absolute worktree path that resolves from
# both sides of the container boundary. Compose mounts the checkout at its host
# path as a second alias for that purpose; the ordinary workspace remains
# /workspaces/glowcap.
glowcap_devcontainer_validate_checkout_dir() {
    local root="$1" configured expected
    configured="$(glowcap_devcontainer_env_value "${root}" GLOWCAP_CHECKOUT_DIR)"
    if [[ -z "${configured}" ]]; then
        echo "devcontainer: GLOWCAP_CHECKOUT_DIR is missing from ${root}/.env" >&2
        return 1
    fi
    expected="$(cd "${root}/.." && pwd -P)" || return
    if [[ "${configured}" != "${expected}" ]]; then
        echo "devcontainer: GLOWCAP_CHECKOUT_DIR=${configured}" >&2
        echo "devcontainer: expected ${expected}" >&2
        return 1
    fi
}

# Linked worktrees store their administrative state in the primary checkout's
# common Git directory. Their .git file may contain an absolute host path, so
# Compose must mount that directory at the same path inside the container.
glowcap_devcontainer_validate_git_common_dir() {
    local root="$1" configured expected
    configured="$(glowcap_devcontainer_env_value "${root}" GLOWCAP_GIT_COMMON_DIR)"
    if [[ -z "${configured}" ]]; then
        echo "devcontainer: set GLOWCAP_GIT_COMMON_DIR in .devcontainer/.env" >&2
        echo "devcontainer: obtain it with: git rev-parse --path-format=absolute --git-common-dir" >&2
        return 1
    fi
    expected="$(git -C "${root}/.." rev-parse --path-format=absolute --git-common-dir)"
    if [[ "${configured}" != "${expected}" ]]; then
        echo "devcontainer: GLOWCAP_GIT_COMMON_DIR=${configured}" >&2
        echo "devcontainer: expected ${expected}" >&2
        return 1
    fi
    if [[ ! -d "${configured}" ]]; then
        echo "devcontainer: GLOWCAP_GIT_COMMON_DIR is not a directory: ${configured}" >&2
        return 1
    fi
}

# Where a checkout keeps one of this directory's entry points.
#
# A grid spans checkouts that sit on different branches, so a column's
# .devcontainer/ is routinely older or newer than the launcher's. The
# commands moved into bin/, so both spellings are looked for, newest first.
# This is the one place that knows a checkout may be behind, and it can be
# deleted once no branch in play predates the move.
glowcap_devcontainer_checkout_entry() {
    local checkout="$1" name="$2" candidate
    for candidate in "bin/${name}" "${name}"; do
        if [[ -x "${checkout}/.devcontainer/${candidate}" ]]; then
            printf '%s\n' "${checkout}/.devcontainer/${candidate}"
            return 0
        fi
    done
    return 1
}
