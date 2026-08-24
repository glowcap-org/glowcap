# shellcheck shell=bash
# What update-pins tracks and where each version comes from: the dependency
# table, the release channel behind every row, and the procedure for the two
# rows a script must not bump on its own.
#
# Adding a dependency is four edits here: a name in PANCAKE_PINS_DEPS, its
# pins.sh variable in pancake_pins_dep_var, how a bump is proven in
# pancake_pins_dep_class and pancake_pins_dep_gate, and the query in
# pancake_pins_latest_version. A file that also restates the pin belongs in
# update-pins-companions.sh instead.

pancake_pins_fetch() {
    curl --fail --location --silent --show-error "$@"
}

pancake_pins_npm_latest() {
    pancake_pins_fetch "https://registry.npmjs.org/$1/latest" | jq -r .version
}

pancake_pins_github_latest_tag() {
    pancake_pins_fetch "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name
}

# SHA-256 of a GitHub release asset: the API digest when published, else the
# asset itself, downloaded and hashed.
pancake_pins_github_asset_sha256() {
    local repo="$1" tag="$2" asset="$3" digest tmp
    digest="$(pancake_pins_fetch "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
        | jq -r --arg n "${asset}" '.assets[] | select(.name == $n) | .digest')"
    case "${digest}" in
        sha256:*)
            echo "${digest#sha256:}"
            return 0
            ;;
    esac
    tmp="$(mktemp -t pancake-update-pins-XXXXXX)"
    pancake_pins_fetch --output "${tmp}" "https://github.com/${repo}/releases/download/${tag}/${asset}"
    sha256sum "${tmp}" | cut -d' ' -f1
    rm -f "${tmp}"
}

# The digest of a Docker Hub tag's multi-architecture index, which is the form a
# Dockerfile FROM line pins. Asking for exactly one media type is what makes the
# answer reproducible: offer the registry several and it picks, and a
# single-architecture manifest digest would pin the image to one machine.
pancake_pins_docker_hub_index_digest() {
    local repository="$1" tag="$2" token
    token="$(pancake_pins_fetch "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repository}:pull" | jq -r .token)"
    pancake_pins_fetch --output /dev/null --dump-header - \
        --header "Authorization: Bearer ${token}" \
        --header "Accept: application/vnd.oci.image.index.v1+json" \
        "https://registry-1.docker.io/v2/${repository}/manifests/${tag}" \
        | tr -d '\r' \
        | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
}

# SHA-256 of a download that publishes no hash of its own: fetch it and hash
# what arrived.
pancake_pins_url_sha256() {
    local url="$1" tmp
    tmp="$(mktemp -t pancake-update-pins-XXXXXX)"
    pancake_pins_fetch --output "${tmp}" "${url}"
    sha256sum "${tmp}" | cut -d' ' -f1
    rm -f "${tmp}"
}

pancake_pins_require_hex64() {
    if ! [[ "$2" =~ ^[0-9a-f]{64}$ ]]; then
        echo "update-pins: $1: not a SHA-256: '$2'" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# The dependency table. One row per dep: its pins.sh variable, its class, and
# the gate that proves a bump. Classes:
#   safe   - outside the build graph; rebuild + verify-toolchains proves it
#   gated  - in the build graph; the named gate must pass after the rebuild
#   manual - a generation move; bump prints the procedure instead of editing
# ---------------------------------------------------------------------------

PANCAKE_PINS_DEPS="debian zig zls rust rustup-init deno node bun playwright uv python serena claude codex cursor-agent opencode devcontainer-cli racket goblins"

pancake_pins_dep_var() {
    case "$1" in
        debian) echo DEBIAN_BASE_DIGEST ;;
        zig) echo ZIG_VERSION ;;
        zls) echo ZLS_SOURCE_REVISION ;;
        rust) echo RUST_VERSION ;;
        rustup-init) echo RUSTUP_INIT_VERSION ;;
        deno) echo DENO_VERSION ;;
        node) echo NODE_VERSION ;;
        bun) echo BUN_VERSION ;;
        playwright) echo PLAYWRIGHT_VERSION ;;
        uv) echo UV_VERSION ;;
        python) echo OCAPN_CONFORMANCE_PYTHON ;;
        serena) echo SERENA_AGENT_VERSION ;;
        claude) echo CLAUDE_CODE_VERSION ;;
        codex) echo CODEX_VERSION ;;
        cursor-agent) echo CURSOR_AGENT_VERSION ;;
        opencode) echo OPENCODE_VERSION ;;
        devcontainer-cli) echo DEVCONTAINER_CLI_VERSION ;;
        racket) echo RACKET_VERSION ;;
        goblins) echo GOBLINS_REVISION ;;
        *)
            echo "update-pins: unknown dep '$1' (deps: ${PANCAKE_PINS_DEPS})" >&2
            return 1
            ;;
    esac
}

pancake_pins_dep_class() {
    case "$1" in
        zls | uv | serena | claude | codex | cursor-agent | opencode | devcontainer-cli) echo safe ;;
        racket | goblins) echo manual ;;
        *) echo gated ;;
    esac
}

pancake_pins_dep_gate() {
    case "$1" in
        debian) echo "zig build check" ;;
        zig) echo "zig build check with the new toolchain" ;;
        zls) echo "rebuild + post-create.sh (verify-toolchains)" ;;
        rust) echo "zig build check (rust-dogfood rides it)" ;;
        rustup-init | deno | node | bun) echo "zig build check" ;;
        playwright) echo "rebuild (new baked Chromium), then zig build rooms-web-page and siblings" ;;
        python) echo "zig build ocapn-conformance" ;;
        racket | goblins) echo "zig build check-external" ;;
        *) echo "rebuild + post-create.sh (verify-toolchains)" ;;
    esac
}

# Every consumer below reads its whole input: under `set -o pipefail`, an
# early-exiting head / grep -m1 / awk-exit closes the pipe and turns curl's
# EPIPE into a query failure.
pancake_pins_latest_version() {
    case "$1" in
        debian) pancake_pins_docker_hub_index_digest library/debian "${DEBIAN_BASE_TAG}" ;;
        zig) pancake_pins_fetch https://ziglang.org/download/index.json | jq -r .master.version ;;
        zls) pancake_pins_fetch https://api.github.com/repos/zigtools/zls/commits/master | jq -r .sha ;;
        # Several packages in the channel file carry a version line; only
        # [pkg.rust]'s is the toolchain version.
        rust) pancake_pins_fetch https://static.rust-lang.org/dist/channel-rust-stable.toml \
            | awk '/^\[pkg\.rust\]$/ { in_rust = 1; next }
                   in_rust && /^version = / { gsub(/[^0-9.]/, "", $3); print $3; in_rust = 0 }' ;;
        rustup-init) pancake_pins_fetch https://static.rust-lang.org/rustup/release-stable.toml \
            | awk -F"'" '/^version = / && !done { print $2; done = 1 }' ;;
        deno) pancake_pins_github_latest_tag denoland/deno | sed 's/^v//' ;;
        # Newest release of the pinned major; a newer major is a deliberate move.
        node) pancake_pins_fetch https://nodejs.org/dist/index.json \
            | jq -r --arg p "v${NODE_VERSION%%.*}." \
                '[.[] | select(.version | startswith($p))][0].version' | sed 's/^v//' ;;
        bun) pancake_pins_github_latest_tag oven-sh/bun | sed 's/^bun-v//' ;;
        playwright) pancake_pins_npm_latest playwright ;;
        uv) pancake_pins_github_latest_tag astral-sh/uv ;;
        # Newest patch of the pinned minor that the pinned uv can install.
        python) uv python list --all-versions 2>/dev/null \
            | grep -oE "cpython-${OCAPN_CONFORMANCE_PYTHON%.*}\.[0-9]+" \
            | sed 's/^cpython-//' | sort -uV | tail -1 ;;
        serena) pancake_pins_fetch https://pypi.org/pypi/serena-agent/json | jq -r .info.version ;;
        claude) pancake_pins_npm_latest @anthropic-ai/claude-code ;;
        codex) pancake_pins_npm_latest @openai/codex ;;
        # Cursor publishes no version index for the agent CLI. Its own install
        # script is the release channel: it hardcodes the current build into
        # the download URL, so read the build out of the URL.
        cursor-agent) pancake_pins_fetch https://cursor.com/install \
            | sed -n 's|^.*downloads\.cursor\.com/lab/\([^/]*\)/.*$|\1|p' | sort -u ;;
        opencode) pancake_pins_github_latest_tag sst/opencode | sed 's/^v//' ;;
        devcontainer-cli) pancake_pins_npm_latest @devcontainers/cli ;;
        racket) pancake_pins_fetch https://download.racket-lang.org/all-versions.html \
            | awk 'match($0, /v[0-9]+\.[0-9]+/) && !done {
                       print substr($0, RSTART + 1, RLENGTH - 1); done = 1
                   }' ;;
        goblins) git ls-remote https://codeberg.org/spritely/racket-goblins.git HEAD | cut -f1 ;;
    esac
}

pancake_pins_manual_procedure() {
    case "$1" in
        racket)
            cat <<'EOF'
racket is a generation move, not a pin bump. Each release serves its own
package catalog, so the pinned package checksums are the ones that move,
not just the version:
  1. Update RACKET_VERSION in pins.sh and the two hashes in
     racket_tarball_and_sha256 (checksums.sh) from
     https://download.racket-lang.org/releases/<version>/installers/.
  2. Install the pinned set into a scratch PLTUSERHOME on the new Racket and
     read back what each package resolved to, because the new catalog may
     serve a different checksum for any of them. Update the ones that moved.
  3. Re-derive the crypto-lib patch: confirm
     patches/crypto-lib-drop-inject-syntax.patch still applies and update
     CRYPTO_LIB_FFI_*_SHA256 either way. They often do not move, since the
     patch is keyed to crypto-lib rather than to the Racket release.
  4. Delete the gitignored compiled/ directories under conformance/ and
     bindings/racket/. They hold bytecode stamped with the old Racket, the
     new one refuses it, and the workspace is a bind mount, so they survive
     the rebuild and would fail the interop steps for a reason that looks
     nothing like a version pin.
  5. Rebuild, then prove it: zig build check-external.
EOF
            ;;
        goblins)
            cat <<'EOF'
goblins is conformance authority, not a pin bump:
  1. Update GOBLINS_VERSION / GOBLINS_REVISION / GOBLINS_SOURCE in pins.sh.
  2. Move the conformance/spritely-goblins/upstream submodule to the same
     revision.
  3. Rebuild, then prove it: zig build check-external.
EOF
            ;;
    esac
}

