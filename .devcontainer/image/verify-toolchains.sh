#!/usr/bin/env bash
# Assert installed toolchains match pins.sh. Apt packages are presence-only.
#
# Every check runs, and the script reports all of them before it exits. Stopping
# at the first failure made this a tripwire rather than a verifier: one tool that
# could not write its state directory ended the run before the checks below it
# were ever attempted, and the container looked verified up to that line and
# unexamined after it.

set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}"
glowcap_require_devcontainer "image/verify-toolchains"

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

# Every pin is read through require_pin (directly or via expect_pin_*), so a
# missing variable is a listed failure and the checks below it still run.
# `set -u` would abort the rest of the run, which is the tripwire behavior
# this file exists to avoid.
require_pin() {
    local label="$1"
    local var="$2"
    if [[ -z "${!var:-}" ]]; then
        fail "${label}: ${var} is not set by this run's pins.sh"
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
expect_pin_equals "zls" ZLS_VERSION zls --version

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
expect_pin_equals "npm" NPM_VERSION npm --version
expect_pin_contains "bun" BUN_VERSION bun --version

# The managed tools (AI harnesses) are not image content, so their absence is
# correct; what the image owes is the wiring. Every managed command name is
# linked to the checkout's dispatcher, a link that dangles during the image
# build and resolves when the workspace bind lands, like the glowcap shim.
tools_wrapper="/workspaces/glowcap/.devcontainer/tools/wrapper.sh"
for managed_name in $(bash -c "source '${GLOWCAP_DEVCONTAINER_DIR}/tools/lib/registry.sh' 2>/dev/null && glowcap_tools_path_names" 2>/dev/null || printf 'claude\ncodex\nopencode\nagent\ncursor-agent\n'); do
    got="$(readlink "/usr/local/bin/${managed_name}" 2>/dev/null || true)"
    if [[ "${got}" != "${tools_wrapper}" ]]; then
        fail "${managed_name}: expected /usr/local/bin link to ${tools_wrapper}, got '${got:-<missing>}'"
    fi
done
if [[ -e "${tools_wrapper}" ]]; then
    if ! bash -n "${tools_wrapper}"; then
        fail "tools/wrapper.sh does not parse"
    fi
    if ! bash -c "source '${GLOWCAP_DEVCONTAINER_DIR}/tools/lib/registry.sh' && glowcap_tools_path_names >/dev/null" 2>/dev/null; then
        fail "the copied tools registry does not load"
    fi
fi

# Browsers are runtime content, not image content: the managed-tool
# lifecycle downloads the pinned requirement into the shared cache and
# launches both Chromium forms through the image-owned libraries, so a
# browser check here would test an install the image does not hold. What the
# image owes is the library set, and the driver's launch verification proves
# it whenever a browser install happens.

expect_pin_contains "rustc" RUST_VERSION rustc --version
expect_pin_contains "cargo" RUST_VERSION cargo --version
expect_ok "rustfmt" rustfmt --version
expect_ok "clippy" cargo clippy --version
if rooms_wasm_version="$(python3 "${dir}/image/rooms-toolchain-version.py")"; then
    expect_contains "wasm-bindgen" "wasm-bindgen ${rooms_wasm_version}" wasm-bindgen --version
else
    fail "wasm-bindgen: cannot read the Rooms lockfile's compiler version"
fi
expect_contains "Rust browser target" "wasm32-unknown-unknown" rustup target list --installed
expect_pin_contains "uv" UV_VERSION uv --version
if require_pin "python" PYTHON_VERSION; then
    expect_contains "python" "${PYTHON_VERSION}" uv python find "${PYTHON_VERSION}"
fi
expect_pin_contains "serena" SERENA_AGENT_VERSION serena --version

# The pane runtime docker-execs /bin/zsh, and the workspace user's login shell
# is that same path. It is an image package so a Dockerfile-only build still
# has the shell post-create requires; the common-utils feature may wrap it.
expect_ok "zsh" /bin/zsh --version

# Tor is presence-only like the other apt packages, and it is checked by running
# the binary rather than testing the path: the Debian package installs it under
# /usr/sbin, which is on the PATH for root and for a login shell but is easy to
# lose, and a `tor` the onion checks cannot execute is the same as no tor.
expect_on_path tor
expect_ok "tor" tor --version

# `rg` is checked as a real program rather than a name: Claude Code defines an
# `rg` shell function in the interactive rc, so a name-only test would pass in a
# shell where every other agent CLI still finds nothing.
expect_on_path gdb lldb strace valgrind perf hyperfine jq nc shellcheck rg
expect_ok "rg" command rg --version
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
