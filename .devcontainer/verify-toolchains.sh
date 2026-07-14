#!/usr/bin/env bash
# Assert installed toolchains match pins.sh. Apt packages are presence-only.

set -euo pipefail

dir="${PANCAKE_DEVCONTAINER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"

expect_contains() {
    local label="$1"
    local needle="$2"
    shift 2
    local output="$("$@")"
    if [[ "${output}" != *"${needle}"* ]]; then
        echo "${label}: expected '${needle}' in '${output}'" >&2
        return 1
    fi
}

[[ "$(zig version)" == "${ZIG_VERSION}" ]]
[[ "$(zls --version)" == "${ZLS_VERSION}" ]]

expect_contains "racket" "${RACKET_VERSION}" racket --version
command -v raco >/dev/null

export PLTUSERHOME
racket -e '(require goblins)'
raco pkg show --long goblins | grep -q "#v${GOBLINS_VERSION}"

expect_contains "deno" "${DENO_VERSION}" deno --version
expect_contains "node" "v${NODE_VERSION}" node --version
command -v npm >/dev/null
expect_contains "bun" "${BUN_VERSION}" bun --version
expect_contains "claude" "${CLAUDE_CODE_VERSION}" claude --version
expect_contains "opencode" "${OPENCODE_VERSION}" opencode --version

expect_contains "rustc" "${RUST_VERSION}" rustc --version
expect_contains "cargo" "${RUST_VERSION}" cargo --version
rustfmt --version
cargo clippy --version
expect_contains "uv" "${UV_VERSION}" uv --version
expect_contains "serena" "${SERENA_AGENT_VERSION}" serena --version

command -v gdb lldb strace valgrind perf hyperfine jq nc >/dev/null
gdb --version >/dev/null
lldb --version >/dev/null
strace --version >/dev/null
valgrind --version >/dev/null
perf --version >/dev/null
hyperfine --version >/dev/null
jq --version >/dev/null
