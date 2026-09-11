#!/usr/bin/env bash
# Idempotently initialize the conformance upstream submodules:
#   - ocapn-conformance/upstream  (the OCapN test suite)
#   - ocapn-spec/upstream         (OCapN spec, for citations)
#   - syrup/upstream              (Syrup spec, for citations)
#   - spritely-goblins/upstream   (Goblins source, for wire-shape lookup)
# Safe to re-run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

paths=(
    conformance/ocapn-conformance/upstream
    conformance/ocapn-spec/upstream
    conformance/syrup/upstream
    conformance/spritely-goblins/upstream
)

# A linked worktree keeps each submodule's repository under its own
# `<git-dir>/modules/<path>`, and the checked-out submodule's `.git` file
# names that directory by absolute path. Moving or renaming the primary
# checkout leaves those pointers naming the old location, and `git submodule
# update` then refuses the checkout as "not a git repository". Repoint a
# pointer whose target is gone at the store this worktree's git-dir holds.
git_dir=$(git rev-parse --path-format=absolute --git-dir)
for path in "${paths[@]}"; do
    pointer="${path}/.git"
    [[ -f ${pointer} ]] || continue
    target=$(sed -n 's/^gitdir: //p' "${pointer}")
    case ${target} in
        /*) resolved=${target} ;;
        *) resolved="${path}/${target}" ;;
    esac
    [[ -d ${resolved} ]] && continue
    store="${git_dir}/modules/${path}"
    [[ -d ${store} ]] || continue
    printf 'gitdir: %s\n' "${store}" >"${pointer}"
    echo "repointed ${pointer} at ${store}"
done

git submodule update --init --recursive "${paths[@]}"

# Git writes core.worktree relative to the submodule repository. A linked
# worktree's repository lives under the primary checkout's common Git directory,
# while the checkout itself is mounted at /workspaces/glowcap in the
# devcontainer. The generated relative path consequently resolves on only one
# side of that boundary. The devcontainer mounts the checkout at its host path
# as a second alias; record that stable absolute path so Git status works from
# both the host and the container.
checkout="${GLOWCAP_CHECKOUT_DIR:-$(pwd -P)}"
for path in "${paths[@]}"; do
    store="${git_dir}/modules/${path}"
    [[ -d ${store} ]] || continue
    git config --file "${store}/config" core.worktree "${checkout}/${path}"
    printf 'gitdir: %s\n' "${store}" > "${path}/.git"
done

echo "conformance submodules initialized."
