#!/usr/bin/env bash
# Fix persistent-volume ownership, confirm ptrace, assert pins and config sync.
# Load-bearing project gate: zig build check (not this script).

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"
pancake_require_devcontainer "post-create"

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
        echo "post-create: host agent-state mount is not readable and writable: ${path}" >&2
        exit 1
    fi
done <<< "$(pancake_devcontainer_host_state_rows)"

bash "${dir}/check-env-sync.sh"
bash "${dir}/verify-ptrace.sh"
# Lint the devcontainer's own scripts (and the repo-root pancake shim the
# image links onto PATH), so a shellcheck finding fails container open and
# ci/gates.sh, which runs this script on every push. SCRIPTDIR resolves the
# relative `source=` directives beside each script, whatever the caller's
# working directory is.
shellcheck --external-sources --source-path=SCRIPTDIR "${dir}"/*.sh "${dir}/../pancake"
PANCAKE_DEVCONTAINER_DIR="${dir}" bash "${dir}/verify-toolchains.sh"
