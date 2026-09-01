#!/usr/bin/env bash
# Assert installed toolchains match pins.sh. Apt packages are presence-only.
#
# Every check runs, and the script reports all of them before it exits. Stopping
# at the first failure made this a tripwire rather than a verifier: one tool that
# could not write its state directory ended the run before the checks below it
# were ever attempted, and the container looked verified up to that line and
# unexamined after it.

set -uo pipefail

dir="${PANCAKE_DEVCONTAINER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
# shellcheck source=../lib/playwright.sh
source "${dir}/lib/playwright.sh"
pancake_devcontainer_init "${dir}"
pancake_require_devcontainer "image/verify-toolchains"

failures=()

fail() {
    failures+=("$1")
    echo "image/verify-toolchains: $1" >&2
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

# Every pin is read through require_pin (directly or via expect_pin_*), because
# this script also runs against the pins.sh baked into the image
# (PANCAKE_DEVCONTAINER_DIR), which is one image build behind the repository
# whenever a pin is being added. Under `set -u` a bare reference to the new pin
# would abort the whole run on that skew, which is the tripwire behavior this
# file exists to avoid; reported as a failure, it says what is missing and the
# checks below it still run.
require_pin() {
    local label="$1"
    local var="$2"
    if [[ -z "${!var:-}" ]]; then
        fail "${label}: ${var} is not set by this run's pins.sh (a baked pins.sh runs one image build behind while a pin lands; rebuild, or run against the repository's .devcontainer)"
        return 1
    fi
}

expect_pin_equals() {
    local label="$1"
    local var="$2"
    shift 2
    require_pin "${label}" "${var}" || return 0
    expect_equals "${label}" "${!var}" "$@"
}

expect_pin_contains() {
    local label="$1"
    local var="$2"
    shift 2
    require_pin "${label}" "${var}" || return 0
    expect_contains "${label}" "${!var}" "$@"
}

expect_pin_equals "zig" ZIG_VERSION zig version
if pancake_devcontainer_zls_enabled; then
    expect_pin_equals "zls" ZLS_VERSION zls --version
elif command -v zls >/dev/null; then
    fail "zls: installed even though ZLS_ENABLED=false"
fi

expect_pin_contains "racket" RACKET_VERSION racket --version
expect_on_path raco
expect_ok "raco make" raco help make
expect_ok "raco test" raco help test

if require_pin "compiler" COMPILER_CHECKSUM; then
    expect_pin_contains "compiler" COMPILER_CHECKSUM raco pkg show --all --long compiler
fi
if require_pin "compiler-lib" COMPILER_LIB_CHECKSUM; then
    expect_pin_contains "compiler-lib" COMPILER_LIB_CHECKSUM raco pkg show --all --long compiler-lib
fi

if require_pin "goblins" PLTUSERHOME; then
    export PLTUSERHOME
    expect_ok "goblins" racket -e '(require goblins)'
    expect_pin_contains "goblins" GOBLINS_CHECKSUM raco pkg show --long goblins
fi

expect_pin_contains "deno" DENO_VERSION deno --version
expect_pin_contains "node" NODE_VERSION node --version
expect_on_path npm
expect_pin_contains "bun" BUN_VERSION bun --version
expect_pin_contains "claude" CLAUDE_CODE_VERSION claude --version
expect_pin_contains "opencode" OPENCODE_VERSION opencode --version
expect_pin_contains "codex" CODEX_VERSION codex --version
# Both of the agent CLI's command names are checked, because the image links
# them separately and a broken link is invisible until someone types the other
# one. `agent` is upstream's current name; `cursor-agent` is the original.
# Even `--version` writes a default settings file into the configured state
# directory, and during the image build that directory is the vscode user's
# bind-mount target while this runs as root, so both checks are pointed at a
# scratch directory that goes away with them.
cursor_state="$(mktemp -d -t pancake-cursor-agent-verify-XXXXXX)"
expect_pin_equals "cursor-agent" CURSOR_AGENT_VERSION \
    env "CURSOR_CONFIG_DIR=${cursor_state}" "CURSOR_DATA_DIR=${cursor_state}" cursor-agent --version
expect_pin_equals "cursor-agent (agent)" CURSOR_AGENT_VERSION \
    env "CURSOR_CONFIG_DIR=${cursor_state}" "CURSOR_DATA_DIR=${cursor_state}" agent --version
rm -rf "${cursor_state}"

# The browser proofs launch both Chromium binaries Playwright installs, so both
# are checked, and running each one proves more than a file test would: it needs
# the apt libraries too, and (during post-create, which runs as vscode) it needs
# the image's root-installed files to be readable. Playwright picks the browser
# build number and architecture-specific archive layout, so the resolver owns
# both supported Linux forms. The path pin is read through the same skew guard
# as every version pin above.
if require_pin "playwright" PLAYWRIGHT_BROWSERS_PATH; then
    browsers_path="${PLAYWRIGHT_BROWSERS_PATH}"
    if ! pancake_playwright_binaries "${browsers_path}"; then
        fail "playwright: expected exactly one Chromium and one headless shell under ${browsers_path}; image/playwright.sh puts them there during the image build, so rebuild the container"
    else
        for bin in "${playwright_bins[@]}"; do
            expect_ok "playwright" "${bin}" --version
        done
    fi
fi

expect_pin_contains "rustc" RUST_VERSION rustc --version
expect_pin_contains "cargo" RUST_VERSION cargo --version
expect_ok "rustfmt" rustfmt --version
expect_ok "clippy" cargo clippy --version
expect_pin_contains "uv" UV_VERSION uv --version
if require_pin "ocapn-conformance-python" OCAPN_CONFORMANCE_PYTHON; then
    expect_contains "ocapn-conformance-python" "${OCAPN_CONFORMANCE_PYTHON}" \
        uv python find "${OCAPN_CONFORMANCE_PYTHON}"
fi
expect_pin_contains "serena" SERENA_AGENT_VERSION serena --version

# Tor is presence-only like the other apt packages, and it is checked by running
# the binary rather than testing the path: the Debian package installs it under
# /usr/sbin, which is on the PATH for root and for a login shell but is easy to
# lose, and a `tor` the onion checks cannot execute is the same as no tor.
expect_on_path tor
expect_ok "tor" tor --version

expect_on_path gdb lldb strace valgrind perf hyperfine jq nc shellcheck
expect_ok "shellcheck" shellcheck --version
expect_ok "gdb" gdb --version
expect_ok "lldb" lldb --version
expect_ok "strace" strace --version
expect_ok "valgrind" valgrind --version
expect_ok "perf" perf --version
expect_ok "hyperfine" hyperfine --version
expect_ok "jq" jq --version

if [[ "${#failures[@]}" -gt 0 ]]; then
    echo "image/verify-toolchains: ${#failures[@]} check(s) failed, listed above" >&2
    exit 1
fi
