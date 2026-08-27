#!/usr/bin/env bash
# Confirm host binds are writable, assert pins and config sync, fill submodules.
# Load-bearing project gate: zig build check (not this script).

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_devcontainer_init "${dir}"
pancake_require_devcontainer "hooks/post-create"
command -v zsh >/dev/null || {
    echo "hooks/post-create: zsh is not on PATH; the workspace user shell and the pane runtime require it" >&2
    exit 1
}

mkdir -p \
    "${BUN_CACHE_DIR}" \
    "${BUN_INSTALL_CACHE_DIR}" \
    "${DENO_DIR}" \
    "${NPM_CACHE_DIR}" \
    "${PIP_CACHE_DIR}" \
    "${UV_CACHE_DIR}" \
    "${ZIG_CACHE_DIR}" \
    "${CACHE_ROOT}/zls" \
    "${CARGO_HOME_RUNTIME}"
if [[ -n "${PANCAKE_WORKTREE:-}" ]]; then
    mkdir -p \
        "${WORK_CACHE_DIR}/${PANCAKE_WORKTREE}/zig-local" \
        "${WORK_CACHE_DIR}/${PANCAKE_WORKTREE}/zig-pkg"
fi

for path in "${PANCAKE_CACHE_DIR}" "${CACHE_ROOT}" "${CARGO_HOME_RUNTIME}"; do
    probe="${path}/.write-test-$$"
    touch "${probe}"
    rm -f "${probe}"
done
if [[ -n "${PANCAKE_WORKTREE:-}" ]]; then
    probe="${WORK_CACHE_DIR}/${PANCAKE_WORKTREE}/zig-local/.write-test-$$"
    touch "${probe}"
    rm -f "${probe}"
    probe="${WORK_CACHE_DIR}/${PANCAKE_WORKTREE}/zig-pkg/.write-test-$$"
    touch "${probe}"
    rm -f "${probe}"
fi

# Once Zig local cache and packages have a home on the host bind, leftover
# checkout copies are unused. Remove them here, before a build, so the
# worktree is not carrying two caches. Racket bytecode is the same shape: it
# is gitignored generated state stamped with the compiler that wrote it, and
# a rebuild leaves it on the workspace bind, where the next Racket then
# refuses it with a version mismatch that does not name the pin.
repo="$(cd "${dir}/.." && pwd)"
if [[ -n "${ZIG_LOCAL_CACHE_DIR:-}" && -n "${ZIG_LOCAL_PKG_DIR:-}" ]]; then
    for leftover in \
        "${repo}/.zig-cache" \
        "${repo}/zig-pkg" \
        "${repo}/site/zig-pkg" \
        "${repo}/tools/consumer/zig-pkg"; do
        if [[ -e "${leftover}" ]]; then
            rm -rf "${leftover}"
        fi
    done
fi
while IFS= read -r leftover; do
    rm -rf "${leftover}"
done < <(find "${repo}" \
    \( -name node_modules -o -name .git -o -name zig-out -o -name target -o -name .zig-cache \) -prune \
    -o -type d -name compiled -prune -print)

# Image content, not a filling cache: raco pkg install writes here.
sudo chown -R vscode:vscode "${PLTUSERHOME}"
probe="${PLTUSERHOME}/.write-test-$$"
touch "${probe}"
rm -f "${probe}"

# Host binds: never recursively chown them from a container. The devcontainer
# user must still be able to use the host user's stores.
while IFS=: read -r _ path; do
    if [[ ! -r "${path}" || ! -w "${path}" ]]; then
        echo "hooks/post-create: host bind is not readable and writable: ${path}" >&2
        exit 1
    fi
done <<< "$(pancake_devcontainer_host_home_bind_rows)"

bash "${dir}/test/env-sync.sh"
# Linked worktrees do not inherit submodule working trees from the clone.
# CI checks them out with the repository; this hook fills them here so every
# checkout is a complete environment.
bash "${dir}/../conformance/bootstrap-submodules.sh"
bash "${dir}/hooks/verify-ptrace.sh"
# Lint the devcontainer's own scripts (and the repo-root pancake shim the
# image links onto PATH), so a shellcheck finding fails container open and
# ci/gates.sh, which runs this script on every push. SCRIPTDIR resolves the
# relative `source=` directives beside each script, whatever the caller's
# working directory is.
# The lint covers every shell file this directory owns, wherever it sits:
# the scripts, the library modules, and the pane runtime's host half. The
# runtime's container half is zsh, a language this linter does not read, so
# it is not offered one. Settings live in .devcontainer/.shellcheckrc, so an
# editor and this hook agree.
mapfile -t devcontainer_shell_files < <(
    find "${dir}" -name '*.sh' | sort
)
shellcheck --external-sources --source-path=SCRIPTDIR \
    "${devcontainer_shell_files[@]}" "${dir}/pane/host/.bashrc" "${dir}/../pancake"
PANCAKE_DEVCONTAINER_DIR="${dir}" bash "${dir}/image/verify-toolchains.sh"
