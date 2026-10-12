#!/usr/bin/env bash
# Install the system libraries the pinned Playwright's Chromium needs, as the
# image's one browser-related job. The browsers themselves are not image
# content: the managed-tool lifecycle (.devcontainer/tools/lib/playwright.sh)
# downloads the exact pinned requirement into the shared cache on first
# browser use, and the image-owned libraries are what those downloads launch
# against. `--with-deps` lets the pinned Playwright name its own apt packages,
# so the library set derives from the version rather than a copied list that
# would drift the next time the pin moves.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}"
glowcap_require_devcontainer "image/playwright"
glowcap_require_arch "playwright chromium"

tmp="$(mktemp -d -t glowcap-playwright-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

export DEBIAN_FRONTEND=noninteractive

# npx caches the downloaded package under npm_config_cache, which points at a
# runtime host bind. Writing there during the image build would leave a
# root-owned directory for the bind to cover, so send this one download to a
# scratch dir instead.
export npm_config_cache="${tmp}/npm"

# `--with-deps` runs the apt operation the runtime driver must never run. No
# browsers land here: without PLAYWRIGHT_BROWSERS_PATH the install would
# fetch them into ~/.cache/ms-playwright, so only the dependency operation is
# spelled.
npx --yes "playwright@${PLAYWRIGHT_VERSION}" install-deps chromium
