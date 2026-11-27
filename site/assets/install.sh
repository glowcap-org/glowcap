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
# tools/check/install_test.py exercises this script against a local release mirror.
set -eu

repository="glowcap-org/glowcap"
api="${GLOWCAP_RELEASES_API:-https://api.github.com/repos/$repository/releases?per_page=100}"
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

work="$(mktemp -d "${TMPDIR:-/tmp}/glowcap-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT HUP INT PIPE TERM

# Read only each release object's tag_name and draft fields. A field in a
# nested asset, or JSON-looking text inside release notes, is unrelated.
public_versions() {
    LC_ALL=C awk '
        function token(value) {
            if (!depth && (value != "[" || closed)) exit 1
            if (value == "[" || value == "{") {
                closing[++depth] = (value == "[" ? "]" : "}")
                if (depth == 2) { tag = ""; public = 0 }
            } else if (value == "]" || value == "}") {
                if (closing[depth] != value) exit 1
                if (depth == 2 && value == "}" && public && tag ~ /^"v0\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"$/)
                    print substr(tag, 3, length(tag)-3)
                if (--depth == 0) closed = 1
            } else if (depth == 2) {
                if (value == ":") field = previous
                if (previous == ":" && field == "\"tag_name\"") tag = value
                if (previous == ":" && field == "\"draft\"") public = (value == "false")
            }
            previous = value
        }
        {
            while (length($0)) {
                if (!match($0, /^[[:space:]]+|^"([^"\\]|\\.)*"|^[][{}:,]|^[[:alnum:].+-]+/)) exit 1
                value = substr($0, 1, RLENGTH)
                $0 = substr($0, RLENGTH+1)
                if (value !~ /^[[:space:]]/) token(value)
            }
        }
        END { if (!closed || depth) exit 1 }
    ' "$1"
}

if [ -n "${GLOWCAP_VERSION:-}" ]; then
    version="$GLOWCAP_VERSION"
else
    listing="$api"
    page=1
    while :; do
        curl -fsSL --proto-redir '=https' -H 'Accept: application/vnd.github+json' \
            -D "$work/headers" -o "$work/releases" "$listing" ||
            fail "could not reach the release listing; check the network, or set GLOWCAP_VERSION"
        public_versions "$work/releases" >> "$work/versions" || fail "invalid release listing"
        grep -Eiq '^link:.*;[[:space:]]*rel="next"' "$work/headers" || break
        page=$((page + 1))
        case "$api" in
            *\?*) listing="$api&page=$page" ;;
            *) listing="$api?page=$page" ;;
        esac
    done
    LC_ALL=C sort -t . -k2,2n -k3,3n "$work/versions" > "$work/ordered"
    version="$(tail -n 1 "$work/ordered")"
    [ -n "$version" ] || fail "the release listing names no supported public release"
fi
echo "$version" | grep -Eq '^0\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || fail "unexpected version: $version"
tag="v$version"
archive="glowcap-$tag-$target.tar.gz"
echo "glowcap install: $tag for $target from $base/$tag"

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
