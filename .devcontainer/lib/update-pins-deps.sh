# shellcheck shell=bash
# What update-pins tracks and where each version comes from: the dependency
# table, the release channel behind every row, and the procedure for the two
# rows a script must not bump on its own.
#
# Adding a dependency is four edits here: a name in GLOWCAP_PINS_DEPS, its
# pins.sh variable in glowcap_pins_dep_var, how a bump is proven in
# glowcap_pins_dep_class and glowcap_pins_dep_gate, and the query in
# glowcap_pins_query_version. A file that also restates the pin belongs in
# update-pins-companions.sh instead.

glowcap_pins_fetch() {
    curl --fail --location --silent --show-error "$@"
}

glowcap_pins_npm_latest() {
    glowcap_pins_fetch "https://registry.npmjs.org/$1/latest" | jq -r .version
}

glowcap_pins_github_latest_tag() {
    glowcap_pins_fetch "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name
}

# SHA-256 of a GitHub release asset: the API digest when published, else the
# asset itself, downloaded and hashed.
glowcap_pins_github_asset_sha256() {
    local repo="$1" tag="$2" asset="$3" digest tmp
    digest="$(glowcap_pins_fetch "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
        | jq -r --arg n "${asset}" '.assets[] | select(.name == $n) | .digest')"
    case "${digest}" in
        sha256:*)
            echo "${digest#sha256:}"
            return 0
            ;;
    esac
    tmp="$(mktemp -t glowcap-update-pins-XXXXXX)"
    glowcap_pins_fetch --output "${tmp}" "https://github.com/${repo}/releases/download/${tag}/${asset}"
    sha256sum "${tmp}" | cut -d' ' -f1
    rm -f "${tmp}"
}

# The digest of a Docker Hub tag's multi-architecture index, which is the form a
# Dockerfile FROM line pins. Asking for exactly one media type is what makes the
# answer reproducible: offer the registry several and it picks, and a
# single-architecture manifest digest would pin the image to one machine.
glowcap_pins_docker_hub_index_digest() {
    local repository="$1" tag="$2" token
    token="$(glowcap_pins_fetch "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repository}:pull" | jq -r .token)"
    glowcap_pins_fetch --output /dev/null --dump-header - \
        --header "Authorization: Bearer ${token}" \
        --header "Accept: application/vnd.oci.image.index.v1+json" \
        "https://registry-1.docker.io/v2/${repository}/manifests/${tag}" \
        | tr -d '\r' \
        | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
}

# SHA-256 of a download that publishes no hash of its own: fetch it and hash
# what arrived.
glowcap_pins_url_sha256() {
    local url="$1" tmp
    tmp="$(mktemp -t glowcap-update-pins-XXXXXX)"
    glowcap_pins_fetch --output "${tmp}" "${url}"
    sha256sum "${tmp}" | cut -d' ' -f1
    rm -f "${tmp}"
}

glowcap_pins_require_hex64() {
    if ! [[ "$2" =~ ^[0-9a-f]{64}$ ]]; then
        echo "update-pins: $1: not a SHA-256: '$2'" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# The dependency table. One row per dep: its pins.sh variable, its class, and
# the gate that proves a bump. Classes:
#   safe   - outside the build graph; the named gate proves it (a rebuild for
#            image-installed tools, a managed-tool ensure or smoke run for the
#            harness seeds)
#   gated  - in the build graph; the named gate must pass after the rebuild
#   manual - a generation move; bump prints the procedure instead of editing
# ---------------------------------------------------------------------------

GLOWCAP_PINS_DEPS="debian distroless postgres zig zls rust rustup-init deno node npm bun playwright uv python serena claude codex cursor-agent opencode devcontainer-cli racket goblins"

glowcap_pins_dep_var() {
    case "$1" in
        debian) echo DEBIAN_BASE_DIGEST ;;
        distroless) echo DISTROLESS_BASE_DIGEST ;;
        postgres) echo POSTGRES_IMAGE_PIN ;;
        zig) echo ZIG_VERSION ;;
        zls) echo ZLS_SOURCE_REVISION ;;
        rust) echo RUST_VERSION ;;
        rustup-init) echo RUSTUP_INIT_VERSION ;;
        deno) echo DENO_VERSION ;;
        node) echo NODE_VERSION ;;
        npm) echo NPM_VERSION ;;
        bun) echo BUN_VERSION ;;
        playwright) echo PLAYWRIGHT_VERSION ;;
        uv) echo UV_VERSION ;;
        python) echo PYTHON_VERSION ;;
        serena) echo SERENA_AGENT_VERSION ;;
        claude) echo CLAUDE_CODE_VERSION ;;
        codex) echo CODEX_VERSION ;;
        cursor-agent) echo CURSOR_AGENT_VERSION ;;
        opencode) echo OPENCODE_VERSION ;;
        devcontainer-cli) echo DEVCONTAINER_CLI_VERSION ;;
        racket) echo RACKET_VERSION ;;
        goblins) echo GOBLINS_REVISION ;;
        *)
            echo "update-pins: unknown dep '$1' (deps: ${GLOWCAP_PINS_DEPS})" >&2
            return 1
            ;;
    esac
}

glowcap_pins_dep_class() {
    case "$1" in
        zls | npm | uv | serena | claude | codex | cursor-agent | opencode | devcontainer-cli) echo safe ;;
        racket | goblins) echo manual ;;
        *) echo gated ;;
    esac
}

glowcap_pins_dep_gate() {
    case "$1" in
        debian) echo "zig build check" ;;
        distroless) echo "release workflow Linux image proofs" ;;
        postgres) echo "docker compose config + zig build rooms-rust-test" ;;
        zig) echo "zig build check with the new toolchain" ;;
        zls) echo "rebuild + post-create.sh (verify-toolchains)" ;;
        rust) echo "zig build check (rust-dogfood rides it)" ;;
        rustup-init | deno | node | bun) echo "zig build check" ;;
        playwright) echo "rebuild (new baked Chromium), then zig build rooms-web-page and siblings" ;;
        python) echo "zig build ocapn-conformance" ;;
        racket | goblins) echo "zig build check-external" ;;
        claude | codex | opencode | cursor-agent) echo "container: bash .devcontainer/test/tool-install.sh <name> (cold-seed smoke; no rebuild; adopt with tools.sh ensure)" ;;
        *) echo "rebuild + post-create.sh (verify-toolchains)" ;;
    esac
}

# Most pins are installed into the development image. PostgreSQL is consumed
# only by the production Compose project, so rebuilding the devcontainer would
# not adopt or prove it. The harness seeds are not image content either: a
# bump is proven by the cold-seed smoke run, and the running cache adopts it
# on the next explicit ensure or a cold first use.
glowcap_pins_dep_requires_devcontainer_rebuild() {
    case "$1" in
        postgres | distroless | claude | codex | opencode | cursor-agent) return 1 ;;
        *) return 0 ;;
    esac
}

# Every consumer below reads its whole input: under `set -o pipefail`, an
# early-exiting head / grep -m1 / awk-exit closes the pipe and turns curl's
# EPIPE into a query failure.
glowcap_pins_query_version() {
    case "$1" in
        debian) glowcap_pins_docker_hub_index_digest library/debian "${DEBIAN_BASE_TAG}" ;;
        distroless)
            glowcap_pins_fetch --output /dev/null --dump-header - \
                --header "Accept: application/vnd.oci.image.index.v1+json" \
                https://gcr.io/v2/distroless/cc-debian13/manifests/latest \
                | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
            ;;
        postgres)
            local version digest
            version="$(glowcap_pins_fetch https://www.postgresql.org/versions.json \
                | jq -r '[.[] | select(.current == true)] | max_by(.major | tonumber) | "\(.major).\(.latestMinor)"')"
            digest="$(glowcap_pins_docker_hub_index_digest library/postgres "${version}-alpine")"
            printf '%s-alpine@%s\n' "${version}" "${digest}"
            ;;
        zig) glowcap_pins_fetch https://ziglang.org/download/index.json | jq -r .master.version ;;
        zls) glowcap_pins_fetch https://api.github.com/repos/zigtools/zls/commits/master | jq -r .sha ;;
        # Several packages in the channel file carry a version line; only
        # [pkg.rust]'s is the toolchain version.
        rust) glowcap_pins_fetch https://static.rust-lang.org/dist/channel-rust-stable.toml \
            | awk '/^\[pkg\.rust\]$/ { in_rust = 1; next }
                   in_rust && /^version = / { gsub(/[^0-9.]/, "", $3); print $3; in_rust = 0 }' ;;
        rustup-init) glowcap_pins_fetch https://static.rust-lang.org/rustup/release-stable.toml \
            | awk -F"'" '/^version = / && !done { print $2; done = 1 }' ;;
        deno) glowcap_pins_github_latest_tag denoland/deno | sed 's/^v//' ;;
        # Newest release of the pinned major; a newer major is a deliberate move.
        node) glowcap_pins_fetch https://nodejs.org/dist/index.json \
            | jq -r --arg p "v${NODE_VERSION%%.*}." \
                '[.[] | select(.version | startswith($p))][0].version' | sed 's/^v//' ;;
        npm) glowcap_pins_npm_latest npm ;;
        bun) glowcap_pins_github_latest_tag oven-sh/bun | sed 's/^bun-v//' ;;
        playwright) glowcap_pins_npm_latest playwright ;;
        uv) glowcap_pins_github_latest_tag astral-sh/uv ;;
        # Newest stable CPython that the pinned uv can install. The trailing
        # hyphen excludes prerelease spellings such as 3.15.0rc2.
        python) uv python list --all-versions 2>/dev/null \
            | grep -oE 'cpython-[0-9]+\.[0-9]+\.[0-9]+-' \
            | sed 's/^cpython-//; s/-$//' | sort -uV | tail -1 ;;
        serena) glowcap_pins_fetch https://pypi.org/pypi/serena-agent/json | jq -r .info.version ;;
        claude) glowcap_pins_npm_latest @anthropic-ai/claude-code ;;
        codex) glowcap_pins_npm_latest @openai/codex ;;
        # Cursor publishes no version index for the agent CLI. Its own install
        # script is the release channel: it hardcodes the current build into
        # the download URL, so read the build out of the URL.
        cursor-agent) glowcap_pins_fetch https://cursor.com/install \
            | sed -n 's|^.*downloads\.cursor\.com/lab/\([^/]*\)/.*$|\1|p' | sort -u ;;
        opencode) glowcap_pins_github_latest_tag sst/opencode | sed 's/^v//' ;;
        devcontainer-cli) glowcap_pins_npm_latest @devcontainers/cli ;;
        racket) glowcap_pins_fetch https://download.racket-lang.org/all-versions.html \
            | awk 'match($0, /v[0-9]+\.[0-9]+/) && !done {
                       print substr($0, RSTART + 1, RLENGTH - 1); done = 1
                   }' ;;
        goblins) git ls-remote https://codeberg.org/spritely/racket-goblins.git HEAD | cut -f1 ;;
    esac
}

# Release metadata is input, not shell source. Reject missing JSON fields,
# multiple results, prereleases on stable channels, and shell metacharacters
# before either the report or a staged pins.sh can consume them.
glowcap_pins_latest_version() {
    local dep="$1" version pattern
    version="$(glowcap_pins_query_version "${dep}")" || return 1
    case "${dep}" in
        debian | distroless) pattern='^sha256:[0-9a-f]{64}$' ;;
        postgres) pattern='^[0-9]+\.[0-9]+-alpine@sha256:[0-9a-f]{64}$' ;;
        zls | goblins) pattern='^[0-9a-f]{40}$' ;;
        zig) pattern='^[0-9]+\.[0-9]+\.[0-9]+(-dev\.[0-9]+\+[0-9a-f]+)?$' ;;
        racket) pattern='^[0-9]+\.[0-9]+(\.[0-9]+)?$' ;;
        cursor-agent) pattern='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]+$' ;;
        *) pattern='^[0-9]+\.[0-9]+\.[0-9]+$' ;;
    esac
    if ! [[ "${version}" =~ ${pattern} ]]; then
        printf 'update-pins: %s: invalid upstream version: %q\n' "${dep}" "${version}" >&2
        return 1
    fi
    printf '%s\n' "${version}"
}

glowcap_pins_manual_procedure() {
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
  4. Rebuild. post-create.sh removes leftover compiled/ directories from
     the workspace bind, so bytecode stamped with the previous Racket cannot
     survive into the new image.
  5. Prove it: zig build check-external.
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
