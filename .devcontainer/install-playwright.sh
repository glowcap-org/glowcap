#!/usr/bin/env bash
# Install the pinned Playwright Chromium and its apt packages into the image.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}"
pancake_require_devcontainer "install-playwright"
require_arch "playwright chromium"

tmp="$(mktemp -d -t pancake-playwright-install-XXXXXX)"
trap 'rm -rf "${tmp}"' EXIT

export DEBIAN_FRONTEND=noninteractive
export PLAYWRIGHT_BROWSERS_PATH
mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}"

# npx caches the downloaded package under npm_config_cache, which points at a
# runtime volume mount target. Writing there during the image build would leave
# a root-owned directory for the volume to cover, so send this one download to a
# scratch dir instead.
export npm_config_cache="${tmp}/npm"

# `--with-deps` lets the pinned Playwright name its own apt packages, so the
# system libraries are derived from the version rather than copied into a list
# here that would drift the next time the pin moves. It is an apt operation, and
# apt operations belong to the image, never to a running container.
npx --yes "playwright@${PLAYWRIGHT_VERSION}" install --with-deps chromium

# Root installs the browsers; every proof runs as vscode.
chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}"
