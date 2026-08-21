#!/usr/bin/env bash
# Confirm the browser proofs have the right Chromium to launch, and say what to
# do when they do not. Playwright's own failure names `npx playwright install`,
# which is the wrong remedy here: the devcontainer ships the browsers in its
# image, and a hand-run install would land in a different directory under a
# different owner.
#
# There are two ways to be wrong and they have different remedies. There may be
# no browser at all, or there may be one from a Playwright the pin has since
# moved past. The library names its browser by an internal build number, so
# raising PLAYWRIGHT_VERSION makes every browser already in the image invisible
# to it. This script used to miss that second case, because it only asked
# whether some Chromium existed, so a stale image sailed past here and met
# Playwright's own message instead of this one.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
browsers="${PLAYWRIGHT_BROWSERS_PATH:-${HOME}/.cache/ms-playwright}"

# shellcheck disable=SC1091
source "${root}/.devcontainer/pins.sh"

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
any_chrome=("${browsers}"/chromium-*/chrome-linux/chrome)
shopt -u nullglob

if [[ -n "${expected}" ]]; then
    [[ -x "${expected}" ]] && exit 0
elif [[ "${#any_chrome[@]}" -gt 0 ]]; then
    # No deno, so the best this can ask is whether any Chromium is present. That
    # cannot tell a stale image from a current one, and the caller finds out
    # from Playwright instead.
    exit 0
fi

if [[ -n "${expected}" && "${#present[@]}" -gt 0 ]]; then
    cat >&2 <<EOF
Playwright ${PLAYWRIGHT_VERSION} wants a Chromium this image does not carry, so this
browser proof cannot run.

  wants:   ${expected}
  present: ${present[*]}

The browsers belong to the devcontainer image, and .devcontainer/pins.sh has
moved past the one baked into the container you are in. Rebuild it (Dev
Containers: Rebuild Container) and .devcontainer/image/playwright.sh will
fetch the browser this version asks for.

Playwright is about to suggest \`npx playwright install\`. Do not run it: it
lands outside ${browsers} and under a different owner, so
the next proof will not see it either.
EOF
    exit 1
fi

cat >&2 <<EOF
No Playwright Chromium under ${browsers}, so this browser proof cannot run.

The devcontainer carries one in its image: .devcontainer/image/playwright.sh
installs the browser that Playwright ${PLAYWRIGHT_VERSION} asks for. If you are in the
container, rebuild it (Dev Containers: Rebuild Container).

On a machine of your own, install the same pinned version and its libraries:

  npx playwright@${PLAYWRIGHT_VERSION} install chromium
  sudo npx playwright@${PLAYWRIGHT_VERSION} install-deps chromium

That version is written in one place, .devcontainer/pins.sh, and zig build
source-check holds the root deno.json's playwright import to it.
EOF
exit 1
