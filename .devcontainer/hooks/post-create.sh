#!/usr/bin/env bash
# Fix persistent-volume ownership, confirm ptrace, assert pins and config sync.
# Load-bearing project gate: zig build check (not this script).

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_devcontainer_init "${dir}"
pancake_require_devcontainer "hooks/post-create"

persistent_dirs=(
    "${BUN_CACHE_DIR}"
    "${BUN_INSTALL_CACHE_DIR}"
    "${DENO_DIR}"
    "${NPM_CACHE_DIR}"
    "${PIP_CACHE_DIR}"
    "${ZIG_CACHE_DIR}"
    "${CACHE_ROOT}/zls"
    "${CARGO_HOME_RUNTIME}"
    "${PLTUSERHOME}"
)

sudo mkdir -p "${persistent_dirs[@]}"
sudo chown -R vscode:vscode "${persistent_dirs[@]}"

for path in "${persistent_dirs[@]}"; do
    probe="${path}/.write-test-$$"
    touch "${probe}"
    rm -f "${probe}"
done

# These are host bind mounts, so never recursively chown them from a container.
# The devcontainer user must still be able to use the host user's stores.
while IFS=: read -r _ path; do
    if [[ ! -r "${path}" || ! -w "${path}" ]]; then
        echo "hooks/post-create: host agent-state mount is not readable and writable: ${path}" >&2
        exit 1
    fi
done <<< "$(pancake_devcontainer_host_state_rows)"

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
