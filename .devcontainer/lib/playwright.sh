# shellcheck shell=bash
# Resolve the two Chromium executables the pinned Playwright installed.
#
# Playwright's Linux archives unpack with an architecture-named inner
# directory: `chrome-linux64/` and `chrome-headless-shell-linux64/` on x86_64,
# `chrome-linux-arm64/` and `chrome-headless-shell-linux-arm64/` on arm64.
# Those names are the pinned Playwright's to choose, so a PLAYWRIGHT_VERSION
# bump that renames them is finished here, in one place, and test/host-invariants.sh
# holds both layouts. The image verifier, the browser-proof preflight, and that
# test all resolve through this one function so they cannot disagree about
# what an installed browser looks like.
#
# Not loaded by mod.sh: only those three readers need it, so they source it
# directly, the same terms launcher.sh sits on.

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
        "${browsers_path}"/chromium-*/chrome-linux-arm64/chrome
        "${browsers_path}"/chromium-*/chrome-linux64/chrome
    )
    local headless_candidates=(
        "${browsers_path}"/chromium_headless_shell-*/chrome-headless-shell-linux-arm64/chrome-headless-shell
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
