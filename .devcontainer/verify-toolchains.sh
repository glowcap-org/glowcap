#!/usr/bin/env bash
# Assert installed toolchains match pins.sh. Apt packages are presence-only.
#
# Every check runs, and the script reports all of them before it exits. Stopping
# at the first failure made this a tripwire rather than a verifier: one tool that
# could not write its state directory ended the run before the checks below it
# were ever attempted, and the container looked verified up to that line and
# unexamined after it.

set -uo pipefail

dir="${PANCAKE_DEVCONTAINER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"

failures=()

fail() {
    failures+=("$1")
    echo "verify-toolchains: $1" >&2
}

# Runs the command and fails if it does not exit zero. The output is captured so
# a passing check stays quiet and a failing one can say what it printed.
expect_ok() {
    local label="$1"
    shift
    local output
    if ! output="$("$@" 2>&1)"; then
        fail "${label}: \`$*\` failed: ${output}"
    fi
}

expect_contains() {
    local label="$1"
    local needle="$2"
    shift 2
    local output
    if ! output="$("$@" 2>&1)"; then
        fail "${label}: \`$*\` failed: ${output}"
        return 0
    fi
    if [[ "${output}" != *"${needle}"* ]]; then
        fail "${label}: expected '${needle}' in '${output}'"
    fi
}

expect_equals() {
    local label="$1"
    local wanted="$2"
    shift 2
    local output
    if ! output="$("$@" 2>&1)"; then
        fail "${label}: \`$*\` failed: ${output}"
        return 0
    fi
    if [[ "${output}" != "${wanted}" ]]; then
        fail "${label}: expected '${wanted}', got '${output}'"
    fi
}

expect_on_path() {
    local name
    for name in "$@"; do
        command -v "${name}" >/dev/null || fail "${name}: not on PATH"
    done
}

expect_equals "zig" "${ZIG_VERSION}" zig version
expect_equals "zls" "${ZLS_VERSION}" zls --version

expect_contains "racket" "${RACKET_VERSION}" racket --version
expect_on_path raco

export PLTUSERHOME
expect_ok "goblins" racket -e '(require goblins)'
expect_contains "goblins" "${GOBLINS_CHECKSUM}" raco pkg show --long goblins

expect_contains "deno" "${DENO_VERSION}" deno --version
expect_contains "node" "v${NODE_VERSION}" node --version
expect_on_path npm
expect_contains "bun" "${BUN_VERSION}" bun --version
expect_contains "claude" "${CLAUDE_CODE_VERSION}" claude --version
expect_contains "opencode" "${OPENCODE_VERSION}" opencode --version

# The browser proofs launch both Chromium binaries Playwright installs, so both
# are checked, and running each one proves more than a file test would: it needs
# the apt libraries too, and (during post-create, which runs as vscode) it needs
# the image's root-installed files to be readable. Playwright picks the browser
# build number, so the check globs it rather than restating it here.
#
# The path is read defensively rather than as `${PLAYWRIGHT_BROWSERS_PATH}`,
# because this script also runs against the pins.sh baked into the image
# (`PANCAKE_DEVCONTAINER_DIR`), which is one image build behind the repository
# whenever a pin is being added. Under `set -u` a bare reference would abort the
# whole run on that skew, which is the tripwire behavior this file exists to
# avoid; reported as a failure, it says what is missing and the checks below it
# still run.
browsers_path="${PLAYWRIGHT_BROWSERS_PATH:-}"
if [[ -z "${browsers_path}" ]]; then
    fail "playwright: pins.sh declares no PLAYWRIGHT_BROWSERS_PATH, so there is nowhere to look for a browser"
else
    shopt -s nullglob
    playwright_bins=(
        "${browsers_path}"/chromium-*/chrome-linux/chrome
        "${browsers_path}"/chromium_headless_shell-*/chrome-linux/headless_shell
    )
    shopt -u nullglob
    if [[ "${#playwright_bins[@]}" -lt 2 ]]; then
        fail "playwright: expected a Chromium and a headless shell under ${browsers_path}; install-playwright.sh puts them there during the image build, so rebuild the container"
    else
        for bin in "${playwright_bins[@]}"; do
            expect_ok "playwright" "${bin}" --version
        done
    fi
fi

expect_contains "rustc" "${RUST_VERSION}" rustc --version
expect_contains "cargo" "${RUST_VERSION}" cargo --version
expect_ok "rustfmt" rustfmt --version
expect_ok "clippy" cargo clippy --version
expect_contains "uv" "${UV_VERSION}" uv --version
expect_contains "serena" "${SERENA_AGENT_VERSION}" serena --version

expect_on_path gdb lldb strace valgrind perf hyperfine jq nc
expect_ok "gdb" gdb --version
expect_ok "lldb" lldb --version
expect_ok "strace" strace --version
expect_ok "valgrind" valgrind --version
expect_ok "perf" perf --version
expect_ok "hyperfine" hyperfine --version
expect_ok "jq" jq --version

if [[ "${#failures[@]}" -gt 0 ]]; then
    echo "verify-toolchains: ${#failures[@]} check(s) failed, listed above" >&2
    exit 1
fi
