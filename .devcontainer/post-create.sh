#!/usr/bin/env bash
# Fix persisted cache ownership, confirm ptrace, assert pins and config sync.
# Load-bearing project gate: zig build check (not this script).

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"

cache_dirs=(
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

sudo mkdir -p "${cache_dirs[@]}"
sudo chown -R vscode:vscode "${cache_dirs[@]}"

for path in "${cache_dirs[@]}"; do
    probe="${path}/.write-test-$$"
    touch "${probe}"
    rm -f "${probe}"
done

bash "${dir}/check-env-sync.sh"
bash "${dir}/verify-ptrace.sh"
PANCAKE_DEVCONTAINER_DIR="${dir}" bash "${dir}/verify-toolchains.sh"
