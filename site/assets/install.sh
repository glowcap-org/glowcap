#!/bin/sh
# Install the glowcap CLI + Rooms product from a GitHub release.
#
#   curl -fsSL https://glowcap.org/install.sh | sh
#
# Served by the site from site/assets. Picks the newest release for this
# machine, downloads its checksum file and product archive, verifies the
# archive, extracts it into a fresh temporary directory, and runs the product's
# own `glowcap install`, which places the product under ~/.local/lib/glowcap
# and links `glowcap` into ~/.local/bin. Nothing is written outside the
# temporary directory until the checksum matches. Needs curl, tar, and
# sha256sum or shasum. Redirects may only lead to HTTPS.
#
#   GLOWCAP_VERSION=0.1.1     install that version instead of the newest release
#   GLOWCAP_RELEASES_API      the releases listing (default: the GitHub API)
#   GLOWCAP_RELEASE_BASE_URL  the download base (default: this repository's releases)
#   GLOWCAP_INSTALL_ARGS      extra arguments for `glowcap install`, such as a prefix
#
# Exit status 1 names the refusal: an unsupported platform, no such release, a
# failed download, or a checksum mismatch. To remove an installation, delete
# its directory under ~/.local/lib/glowcap and the ~/.local/bin/glowcap link.
# ci/test/install_test.py exercises this script against a local release mirror.
set -eu

repository="glowcap-org/glowcap"
api="${GLOWCAP_RELEASES_API:-https://api.github.com/repos/$repository/releases?per_page=1}"
base="${GLOWCAP_RELEASE_BASE_URL:-https://github.com/$repository/releases/download}"

fail() {
    echo "glowcap install: $*" >&2
    exit 1
}

for tool in curl tar; do
    command -v "$tool" > /dev/null 2>&1 || fail "needs $tool"
done
if command -v sha256sum > /dev/null 2>&1; then
    digest() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum > /dev/null 2>&1; then
    digest() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
    fail "needs sha256sum or shasum"
fi

case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="macos" ;;
    *) fail "no prebuilt product for $(uname -s); build from source: https://github.com/$repository" ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch="x86_64" ;;
    aarch64 | arm64) arch="aarch64" ;;
    *) fail "no prebuilt product for $(uname -m) $os; build from source: https://github.com/$repository" ;;
esac
target="$arch-$os"

if [ -n "${GLOWCAP_VERSION:-}" ]; then
    version="$GLOWCAP_VERSION"
else
    # The newest release, including prereleases. Only the tag field is read,
    # and it must look like a version before it is used in a URL.
    version="$(curl -fsSL --proto-redir '=https' -H 'Accept: application/vnd.github+json' "$api" |
        tr -d '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p')" ||
        fail "could not reach the release listing at $api; check the network, or set GLOWCAP_VERSION"
    [ -n "$version" ] || fail "the release listing at $api names no release"
fi
echo "$version" | grep -Eq '^0\.[0-9]+\.[0-9]+$' || fail "unexpected version: $version"
tag="v$version"
archive="glowcap-$tag-$target.tar.gz"
echo "glowcap install: $tag for $target from $base/$tag"

work="$(mktemp -d "${TMPDIR:-/tmp}/glowcap-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT PIPE TERM
# The checksum file is small and lists every archive of the release, so it
# tells a missing release apart from a missing platform before the download.
curl -fsSL --proto-redir '=https' -o "$work/SHA256SUMS" "$base/$tag/SHA256SUMS" ||
    fail "could not download $base/$tag/SHA256SUMS; the release may not exist, or the network is unreachable"
expected="$(grep " $archive\$" "$work/SHA256SUMS" | cut -d ' ' -f 1)"
[ -n "$expected" ] || fail "release $tag has no product for $target; its SHA256SUMS does not list $archive"
echo "glowcap install: downloading $archive"
curl -fsSL --proto-redir '=https' -o "$work/$archive" "$base/$tag/$archive" ||
    fail "could not download $base/$tag/$archive"
actual="$(digest "$work/$archive")"
[ "$actual" = "$expected" ] || fail "checksum mismatch for $archive: expected $expected, downloaded $actual"
echo "glowcap install: verified $archive against SHA256SUMS"

mkdir "$work/product"
tar -xzf "$work/$archive" -C "$work/product"
[ -x "$work/product/bin/glowcap" ] || fail "$archive has no bin/glowcap"
# shellcheck disable=SC2086
"$work/product/bin/glowcap" install ${GLOWCAP_INSTALL_ARGS:-}
echo "glowcap install: done. If 'glowcap' is not found, add ~/.local/bin to your PATH."
