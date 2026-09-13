#!/usr/bin/env bash
# Idempotently initialize the conformance upstream submodules:
#   - ocapn-conformance/upstream  (the OCapN test suite)
#   - ocapn-spec/upstream         (OCapN spec, for citations)
#   - syrup/upstream              (Syrup spec, for citations)
#   - spritely-goblins/upstream   (Goblins source, for wire-shape lookup)
# Safe to re-run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# post-create supplies the host-path bind for linked worktrees. Resolve Git's
# administrative directory through that alias, never the container-only mount.
checkout="${GLOWCAP_CHECKOUT_DIR:-$(pwd -P)}"
if [[ ! ${checkout} -ef . ]]; then
    echo "bootstrap-submodules: GLOWCAP_CHECKOUT_DIR must name this checkout" >&2
    exit 1
fi
cd "${checkout}"

paths=(
    conformance/ocapn-conformance/upstream
    conformance/ocapn-spec/upstream
    conformance/syrup/upstream
    conformance/spritely-goblins/upstream
)

# Normalize both directions before Git reads existing submodules and after it
# initializes new ones. A primary clone carries its stores with it, so relative
# links survive relocation and either container mount. Linked worktree stores
# live outside the checkout and use Compose's identical host-path binds.
git_dir=$(git rev-parse --path-format=absolute --git-dir)
normalize_submodule_links() {
    local path store target worktree
    for path in "${paths[@]}"; do
        store="${git_dir}/modules/${path}"
        [[ -f ${store}/config && -f ${path}/.git ]] || continue
        if [[ -d .git ]]; then
            # All upstreams are conformance/<name>/upstream; their stores are
            # .git/modules/conformance/<name>/upstream.
            target="../../../.git/modules/${path}"
            worktree="../../../../../${path}"
        else
            target="${store}"
            worktree="${checkout}/${path}"
        fi
        git config --file "${store}/config" core.worktree "${worktree}"
        printf 'gitdir: %s\n' "${target}" > "${path}/.git"
    done
}

normalize_submodule_links
git submodule update --init --recursive "${paths[@]}"
normalize_submodule_links

echo "conformance submodules initialized."
