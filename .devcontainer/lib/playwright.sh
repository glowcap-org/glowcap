# shellcheck shell=bash
# Resolve the two Chromium executables the pinned Playwright installed.
#
# Playwright's Linux archives unpack with different inner names per
# architecture: arm64 keeps `chrome-linux/` for both binaries, while x86_64
# uses `chrome-linux64/` for the full browser and
# `chrome-headless-shell-linux64/` for the headless shell. This module owns
# both forms so the image verifier and its test agree on one resolver.
#
# Not loaded by mod.sh: only the image verifier and test/host-invariants.sh
# need it, so they source it directly, the same terms launcher.sh sits on.

# Find exactly one full browser and one headless shell under the given
# browsers path, publishing them as `playwright_bins` (browser first). Zero
# matches is a missing installation; more than one is an ambiguous store a
# stale build number left behind. Both fail.
glowcap_playwright_binaries() {
    local browsers_path="$1"
    local restore_nullglob=false
    if ! shopt -q nullglob; then
        shopt -s nullglob
        restore_nullglob=true
    fi
    local chromium_candidates=(
        "${browsers_path}"/chromium-*/chrome-linux/chrome
        "${browsers_path}"/chromium-*/chrome-linux64/chrome
    )
    local headless_candidates=(
        "${browsers_path}"/chromium_headless_shell-*/chrome-linux/headless_shell
        "${browsers_path}"/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell
    )
    if [[ "${restore_nullglob}" == true ]]; then shopt -u nullglob; fi

    if [[ "${#chromium_candidates[@]}" -ne 1 || "${#headless_candidates[@]}" -ne 1 ]]; then
        return 1
    fi
    # The sourcing scripts read this array; per-file analysis cannot see that.
    # shellcheck disable=SC2034
    playwright_bins=("${chromium_candidates[0]}" "${headless_candidates[0]}")
}
