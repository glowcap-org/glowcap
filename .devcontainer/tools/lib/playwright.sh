# shellcheck shell=bash
# Playwright driver: exact-pinned browser assets. The checkout's pin (PLAYWRIGHT_VERSION, held
# in step with every Deno scope's npm:playwright import by update-pins's
# companion rows) is the requirement; the pinned package resolves its own
# browser revisions: revision numbers are never copied into the registry.
#
# The install carries the pinned package and a private browser directory:
# `pkg/` is the package itself (installed with npm --prefix, so the whole
# directory relocates), and `browser/` is PLAYWRIGHT_BROWSERS_PATH for both
# installation and consuming processes. Playwright's browser garbage
# collection is disabled (PLAYWRIGHT_SKIP_BROWSER_GC=1): with several
# requirements coexisting in one cache, GC would delete another worktree's
# exact installation.
#
# The package is installed through npm (registry integrity covers it); the
# browsers are vendor-managed downloads whose digests Playwright resolves,
# no independent checksum verification is invented here. The verification
# launches both required Chromium forms from the published path against the
# image-owned system libraries. The runtime driver never invokes apt or
# sudo; OS libraries remain image-owned (image/playwright.sh).
#
# This is a pinned-policy asset: `tools.sh update` refuses it, `ensure`
# prepares the checkout's exact requirement, and `tools.sh exec playwright`
# supplies the resolved PLAYWRIGHT_BROWSERS_PATH to a command.

glowcap_tools_playwright_download() {
    local requirement="$1" install_dir="$2"
    local browsers_dir="${install_dir}/browser"
    mkdir -p "${install_dir}/pkg" "${browsers_dir}" || return 1
    if ! npm install --prefix "${install_dir}/pkg" --no-fund --no-audit \
        "playwright@${requirement}" </dev/null >&2; then
        echo "playwright driver: npm install of ${requirement} failed" >&2
        return 1
    fi
    if ! env PLAYWRIGHT_BROWSERS_PATH="${browsers_dir}" PLAYWRIGHT_SKIP_BROWSER_GC=1 \
        "${install_dir}/pkg/node_modules/.bin/playwright" install chromium </dev/null >&2; then
        echo "playwright driver: browser install for ${requirement} failed" >&2
        return 1
    fi
    glowcap_tools_record "npm:playwright@${requirement}" package-resolved
}

# The pinned package must resolve both required Chromium forms inside this
# install's browser directory, and each must launch against the image's
# system libraries. Launching both binaries is the check; --version is what
# a headless launch can answer offline. The layout resolver is the same one
# the image verifier and preflight use, so all readers agree on what an
# installed browser looks like.
glowcap_tools_playwright_verify() {
    local install_dir="$1" requirement="$2"
    local browsers_dir="${install_dir}/browser"
    # shellcheck source=../../lib/playwright.sh
    source "${GLOWCAP_DEVCONTAINER_DIR}/lib/playwright.sh"
    if ! glowcap_playwright_binaries "${browsers_dir}"; then
        echo "playwright driver: expected one chromium and one headless shell under ${browsers_dir}" >&2
        return 1
    fi
    local resolved
    resolved="$(NODE_PATH="${install_dir}/pkg/node_modules" PLAYWRIGHT_BROWSERS_PATH="${browsers_dir}" node -e 'const pw=require("playwright");const p=pw.chromium.executablePath();if(!p){process.exit(1)};process.stdout.write(p)' 2>/dev/null)" || {
        echo "playwright driver: the pinned package did not resolve its chromium path" >&2
        return 1
    }
    local bin matched=""
    for bin in "${playwright_bins[@]}"; do
        if [[ "$(dirname "${bin}")" == "$(dirname "${resolved}")" ]]; then
            matched=1
        fi
        if ! "${bin}" --version >/dev/null 2>&1; then
            echo "playwright driver: ${bin} did not launch" >&2
            return 1
        fi
    done
    if [[ -z "${matched}" ]]; then
        echo "playwright driver: the package resolved ${resolved}, not a form this install carries" >&2
        return 1
    fi
}

glowcap_tools_playwright_exec_path() {
    local install_dir="$1"
    [[ -x "${install_dir}/pkg/node_modules/.bin/playwright" ]] || return 1
    printf '%s\n' "${install_dir}/pkg/node_modules/.bin/playwright"
}

# The environment every consuming process needs: the private browser
# directory of this exact requirement, with GC off so one worktree's step
# cannot delete another worktree's installation.
glowcap_tools_playwright_exec_env() {
    local install_dir="${1:-}"
    printf '%s\n' "PLAYWRIGHT_BROWSERS_PATH=${install_dir}/browser"
    printf '%s\n' "PLAYWRIGHT_SKIP_BROWSER_GC=1"
}
