#!/usr/bin/env bash
# The one prerequisite every browser proof hangs from. In the devcontainer it
# prepares the checkout's exact pinned browsers through the managed-tool
# lifecycle: the requirement is PLAYWRIGHT_VERSION, the install lives in the
# shared cache, and a warm check is a structural readiness check. On a host
# build (macOS CI, a machine of your own) it checks the local Playwright
# environment instead and says how to install what is missing, the container
# lifecycle is never invoked there.
#
# The runtime cannot be stale: it installs what the pin asks, keyed by
# requirement, and Playwright's garbage collection is off, so one worktree's
# run cannot delete another's installation. The remaining failure is a failed
# preparation, whose error names the remedy.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -n "${GLOWCAP_DEVCONTAINER_DIR:-}" ]]; then
    exec bash "${root}/.devcontainer/bin/tools.sh" ensure playwright
fi

# Host branch: the local Playwright environment, with actionable diagnostics.
browsers="${PLAYWRIGHT_BROWSERS_PATH:-${HOME}/.cache/ms-playwright}"

# shellcheck disable=SC1091
source "${root}/.devcontainer/pins.sh"
# shellcheck disable=SC1091
source "${root}/.devcontainer/lib/playwright.sh"

# Only Playwright can say which directory a given version looks in, so ask it
# rather than restating the build-number mapping here. Resolution runs through
# the root import map, the same specifier the proofs load.
expected=""
if command -v deno >/dev/null 2>&1; then
    expected="$(cd "${root}" && deno run --quiet --allow-all --config deno.json \
        tools/check/playwright-executable-path.ts 2>/dev/null || true)"
fi

shopt -s nullglob
present=("${browsers}"/chromium-*)
shopt -u nullglob

if [[ -n "${expected}" && -x "${expected}" ]]; then
    exit 0
elif [[ -z "${expected}" ]] && glowcap_playwright_binaries "${browsers}"; then
    # No deno, so the best this can ask is whether one Chromium and one
    # headless shell are present, through the same resolver the image verifier
    # uses. That cannot tell a stale store from a current one, and the caller
    # finds out from Playwright instead.
    exit 0
fi

cat >&2 <<EOF
Playwright ${PLAYWRIGHT_VERSION} cannot find its Chromium under ${browsers}, so this
browser proof cannot run.

On a machine of your own, install the same pinned version and its libraries:

  npx playwright@${PLAYWRIGHT_VERSION} install chromium
  sudo npx playwright@${PLAYWRIGHT_VERSION} install-deps chromium

That version is written in one place, .devcontainer/pins.sh, and zig build
source-check holds the root deno.json's playwright import to it.
EOF
exit 1
