#!/usr/bin/env bash
# Manage the devcontainer's pinned dependency versions.
#
#   update-pins.sh [check]         report every pin against upstream, and
#                                  submodule drift; writes nothing
#   update-pins.sh bump <dep>...   rewrite pins.sh (and checksums.sh) to the
#                                  latest version of the named deps
#   update-pins.sh bump --safe     bump every dep outside the build graph,
#                                  the ones a rebuild alone proves
#
# Versions and hashes come from each tool's own release channel (ziglang.org,
# static.rust-lang.org, the GitHub releases API, registry.npmjs.org,
# nodejs.org, pypi.org, download.racket-lang.org, codeberg.org). Edits go
# through staged copies that are validated whole (bash syntax, hash shape,
# anchored replacement) before they land. Checksums land before versions, so
# interruption can leave only an inert future hash, never a version with the
# wrong hash. Run it in the devcontainer, where
# curl, jq, git, and uv are pinned.
#
# Every bump ends with a container rebuild; check prints which build gate
# proves each outdated dep beyond that. racket and goblins are generation
# moves (conformance authority), so bump prints their procedure instead of
# editing.
#
# check exits 0 when everything is current, 1 when updates are available,
# 2 when any upstream query failed.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_devcontainer_init "${dir}" checksums
pancake_require_devcontainer "update-pins"

usage() {
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
}

fetch() {
    curl --fail --location --silent --show-error "$@"
}

npm_latest() {
    fetch "https://registry.npmjs.org/$1/latest" | jq -r .version
}

github_latest_tag() {
    fetch "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name
}

# SHA-256 of a GitHub release asset: the API digest when published, else the
# asset itself, downloaded and hashed.
github_asset_sha256() {
    local repo="$1" tag="$2" asset="$3" digest tmp
    digest="$(fetch "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
        | jq -r --arg n "${asset}" '.assets[] | select(.name == $n) | .digest')"
    case "${digest}" in
        sha256:*)
            echo "${digest#sha256:}"
            return 0
            ;;
    esac
    tmp="$(mktemp -t pancake-update-pins-XXXXXX)"
    fetch --output "${tmp}" "https://github.com/${repo}/releases/download/${tag}/${asset}"
    sha256sum "${tmp}" | cut -d' ' -f1
    rm -f "${tmp}"
}

# SHA-256 of a download that publishes no hash of its own: fetch it and hash
# what arrived.
url_sha256() {
    local url="$1" tmp
    tmp="$(mktemp -t pancake-update-pins-XXXXXX)"
    fetch --output "${tmp}" "${url}"
    sha256sum "${tmp}" | cut -d' ' -f1
    rm -f "${tmp}"
}

require_hex64() {
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

ALL_DEPS="zig rust rustup-init deno node bun playwright uv python serena claude codex cursor-agent opencode devcontainer-cli racket goblins"

dep_var() {
    case "$1" in
        zig) echo ZIG_VERSION ;;
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
            echo "update-pins: unknown dep '$1' (deps: ${ALL_DEPS})" >&2
            return 1
            ;;
    esac
}

dep_class() {
    case "$1" in
        uv | serena | claude | codex | cursor-agent | opencode | devcontainer-cli) echo safe ;;
        racket | goblins) echo manual ;;
        *) echo gated ;;
    esac
}

dep_gate() {
    case "$1" in
        zig) echo "zig build check with the new toolchain (zls bumps in lockstep)" ;;
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
latest_version() {
    case "$1" in
        zig) fetch https://ziglang.org/download/index.json \
            | jq -r '[keys[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
                       | { raw: ., parts: (split(".") | map(tonumber)) }]
                     | sort_by(.parts) | last.raw' ;;
        # Several packages in the channel file carry a version line; only
        # [pkg.rust]'s is the toolchain version.
        rust) fetch https://static.rust-lang.org/dist/channel-rust-stable.toml \
            | awk '/^\[pkg\.rust\]$/ { in_rust = 1; next }
                   in_rust && /^version = / { gsub(/[^0-9.]/, "", $3); print $3; in_rust = 0 }' ;;
        rustup-init) fetch https://static.rust-lang.org/rustup/release-stable.toml \
            | awk -F"'" '/^version = / && !done { print $2; done = 1 }' ;;
        deno) github_latest_tag denoland/deno | sed 's/^v//' ;;
        # Newest release of the pinned major; a newer major is a deliberate move.
        node) fetch https://nodejs.org/dist/index.json \
            | jq -r --arg p "v${NODE_VERSION%%.*}." \
                '[.[] | select(.version | startswith($p))][0].version' | sed 's/^v//' ;;
        bun) github_latest_tag oven-sh/bun | sed 's/^bun-v//' ;;
        playwright) npm_latest playwright ;;
        uv) github_latest_tag astral-sh/uv ;;
        # Newest patch of the pinned minor that the pinned uv can install.
        python) uv python list --all-versions 2>/dev/null \
            | grep -oE "cpython-${OCAPN_CONFORMANCE_PYTHON%.*}\.[0-9]+" \
            | sed 's/^cpython-//' | sort -uV | tail -1 ;;
        serena) fetch https://pypi.org/pypi/serena-agent/json | jq -r .info.version ;;
        claude) npm_latest @anthropic-ai/claude-code ;;
        codex) npm_latest @openai/codex ;;
        # Cursor publishes no version index for the agent CLI. Its own install
        # script is the release channel: it hardcodes the current build into
        # the download URL, so read the build out of the URL.
        cursor-agent) fetch https://cursor.com/install \
            | sed -n 's|^.*downloads\.cursor\.com/lab/\([^/]*\)/.*$|\1|p' | sort -u ;;
        opencode) github_latest_tag sst/opencode | sed 's/^v//' ;;
        devcontainer-cli) npm_latest @devcontainers/cli ;;
        racket) fetch https://download.racket-lang.org/all-versions.html \
            | awk 'match($0, /v[0-9]+\.[0-9]+/) && !done {
                       print substr($0, RSTART + 1, RLENGTH - 1); done = 1
                   }' ;;
        goblins) git ls-remote https://codeberg.org/spritely/racket-goblins.git HEAD | cut -f1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Staged edits. Each helper rewrites one shape in a staged copy and fails if
# the anchor it expects is missing, so a drifted file shape aborts the bump
# instead of silently editing nothing.
# ---------------------------------------------------------------------------

replace_pin_line() {
    local file="$1" var="$2" value="$3" tmp="$1.edit"
    awk -v var="${var}" -v value="${value}" '
        $0 ~ "^" var "=\"" { print var "=\"" value "\""; done = 1; next }
        { print }
        END { if (!done) exit 3 }
    ' "${file}" > "${tmp}" || {
        echo "update-pins: ${var} not found in pins.sh" >&2
        rm -f "${tmp}"
        return 1
    }
    mv "${tmp}" "${file}"
}

# Rewrite the two hash lines of a pick_by_arch checksum function: x86_64
# value, then aarch64.
replace_arch_hashes() {
    local file="$1" fn="$2" x86="$3" a64="$4" tmp="$1.edit"
    require_hex64 "${fn} x86_64" "${x86}"
    require_hex64 "${fn} aarch64" "${a64}"
    awk -v fn="${fn}" -v x86="${x86}" -v a64="${a64}" '
        n > 0 {
            indent = $0; sub(/[^ ].*$/, "", indent)
            if (n == 2) print indent "\"" x86 "\" \\"
            else print indent "\"" a64 "\""
            n--; next
        }
        $0 ~ ("pick_by_arch " fn " \\\\$") { print; n = 2; found = 1; next }
        { print }
        END { if (!found || n != 0) exit 3 }
    ' "${file}" > "${tmp}" || {
        echo "update-pins: pick_by_arch ${fn} block not found in checksums.sh" >&2
        rm -f "${tmp}"
        return 1
    }
    mv "${tmp}" "${file}"
}

# Rewrite one platform arm of zig_sha256's OS-arch case.
replace_zig_hash() {
    local file="$1" key="$2" hash="$3" tmp="$1.edit"
    require_hex64 "zig ${key}" "${hash}"
    awk -v key="${key}" -v hash="${hash}" '
        $0 ~ key "\\) echo \"[0-9a-f]*\"" {
            sub(/echo "[0-9a-f]*"/, "echo \"" hash "\""); done = 1
        }
        { print }
        END { if (!done) exit 3 }
    ' "${file}" > "${tmp}" || {
        echo "update-pins: zig_sha256 arm ${key} not found in checksums.sh" >&2
        rm -f "${tmp}"
        return 1
    }
    mv "${tmp}" "${file}"
}

# Per-dep checksum refresh into the staged checksums.sh. Deps without a case
# arm here are pinned by version alone.
refresh_hashes() {
    local dep="$1" version="$2" file="$3"
    case "${dep}" in
        zig)
            local index
            index="$(fetch https://ziglang.org/download/index.json)"
            local key platform hash
            while read -r key platform; do
                hash="$(jq -r --arg v "${version}" --arg p "${platform}" \
                    '.[$v][$p].shasum // empty' <<< "${index}")"
                if [[ -z "${hash}" ]]; then
                    echo "update-pins: zig index has no ${platform} for ${version}" >&2
                    return 1
                fi
                replace_zig_hash "${file}" "${key}" "${hash}"
            done <<'EOF'
Linux-x86_64 x86_64-linux
Linux-aarch64 aarch64-linux
Darwin-arm64 aarch64-macos
Darwin-x86_64 x86_64-macos
EOF
            replace_arch_hashes "${file}" zls_sha256 \
                "$(github_asset_sha256 zigtools/zls "${version}" zls-x86_64-linux.tar.xz)" \
                "$(github_asset_sha256 zigtools/zls "${version}" zls-aarch64-linux.tar.xz)"
            ;;
        rustup-init)
            local base="https://static.rust-lang.org/rustup/archive/${version}"
            replace_arch_hashes "${file}" rustup_init_sha256 \
                "$(fetch "${base}/x86_64-unknown-linux-gnu/rustup-init.sha256" | cut -d' ' -f1)" \
                "$(fetch "${base}/aarch64-unknown-linux-gnu/rustup-init.sha256" | cut -d' ' -f1)"
            ;;
        deno)
            replace_arch_hashes "${file}" deno_sha256 \
                "$(github_asset_sha256 denoland/deno "v${version}" deno-x86_64-unknown-linux-gnu.zip)" \
                "$(github_asset_sha256 denoland/deno "v${version}" deno-aarch64-unknown-linux-gnu.zip)"
            ;;
        node)
            local sums
            sums="$(fetch "https://nodejs.org/dist/v${version}/SHASUMS256.txt")"
            replace_arch_hashes "${file}" node_sha256 \
                "$(awk -v f="node-v${version}-linux-x64.tar.xz" '$2 == f { print $1 }' <<< "${sums}")" \
                "$(awk -v f="node-v${version}-linux-arm64.tar.xz" '$2 == f { print $1 }' <<< "${sums}")"
            ;;
        bun)
            replace_arch_hashes "${file}" bun_sha256 \
                "$(github_asset_sha256 oven-sh/bun "bun-v${version}" bun-linux-x64.zip)" \
                "$(github_asset_sha256 oven-sh/bun "bun-v${version}" bun-linux-aarch64.zip)"
            ;;
        uv)
            replace_arch_hashes "${file}" uv_sha256 \
                "$(github_asset_sha256 astral-sh/uv "${version}" uv-x86_64-unknown-linux-gnu.tar.gz)" \
                "$(github_asset_sha256 astral-sh/uv "${version}" uv-aarch64-unknown-linux-gnu.tar.gz)"
            ;;
        cursor-agent)
            local cursor_base="https://downloads.cursor.com/lab/${version}/linux"
            replace_arch_hashes "${file}" cursor_agent_sha256 \
                "$(url_sha256 "${cursor_base}/x64/agent-cli-package.tar.gz")" \
                "$(url_sha256 "${cursor_base}/arm64/agent-cli-package.tar.gz")"
            ;;
        opencode)
            replace_arch_hashes "${file}" opencode_sha256 \
                "$(github_asset_sha256 sst/opencode "v${version}" opencode-linux-x64.tar.gz)" \
                "$(github_asset_sha256 sst/opencode "v${version}" opencode-linux-arm64.tar.gz)"
            ;;
    esac
}

manual_procedure() {
    case "$1" in
        racket)
            cat <<'EOF'
racket is a generation move, not a pin bump:
  1. Update RACKET_VERSION in pins.sh and the two hashes in
     racket_tarball_and_sha256 (checksums.sh) from
     https://download.racket-lang.org/releases/<version>/installers/.
  2. Re-derive the crypto-lib patch: install into a scratch PLTUSERHOME,
     check whether patches/crypto-lib-racket-*.patch still applies, and
     update CRYPTO_LIB_FFI_*_SHA256 in pins.sh either way.
  3. Rebuild, then prove it: zig build check-external.
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

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

submodule_drift() {
    local drift=0 sha path url head rest
    while read -r sha path rest; do
        sha="${sha#[+-]}"
        url="$(git -C "${dir}/.." config --file .gitmodules "submodule.${path}.url")"
        head="$(git ls-remote "${url}" HEAD 2>/dev/null | cut -f1)" || head=""
        if [[ -z "${head}" ]]; then
            printf '  %-28s upstream query failed (%s)\n' "${path##conformance/}" "${url}"
            drift=2
        elif [[ "${head}" != "${sha}" ]]; then
            printf '  %-28s pinned %.12s, upstream %.12s\n' "${path##conformance/}" "${sha}" "${head}"
            [[ "${drift}" -eq 2 ]] || drift=1
        fi
    done < <(git -C "${dir}/.." submodule status)
    return "${drift}"
}

run_check() {
    local status=0 dep var pinned latest verdict
    printf '%-18s %-14s %-14s %s\n' DEP PINNED LATEST VERDICT
    for dep in ${ALL_DEPS}; do
        var="$(dep_var "${dep}")"
        pinned="${!var}"
        latest="$(latest_version "${dep}" 2>/dev/null)" || latest=""
        if [[ -z "${latest}" ]]; then
            verdict="upstream query failed"
            status=2
        elif [[ "${latest}" == "${pinned}" ]]; then
            verdict="current"
        else
            verdict="update available ($(dep_class "${dep}")); gate: $(dep_gate "${dep}")"
            [[ "${status}" -eq 2 ]] || status=1
        fi
        printf '%-18s %-14.12s %-14.12s %s\n' "${dep}" "${pinned}" "${latest:--}" "${verdict}"
    done
    echo
    echo "submodules (report-only; moving one answers to zig build check-external):"
    local sub_status=0
    submodule_drift || sub_status=$?
    if [[ "${sub_status}" -eq 0 ]]; then
        echo "  all at upstream HEAD"
    elif [[ "${sub_status}" -eq 2 ]]; then
        status=2
    elif [[ "${status}" -eq 0 ]]; then
        status=1
    fi
    return "${status}"
}

# ---------------------------------------------------------------------------
# bump
# ---------------------------------------------------------------------------

run_bump() {
    local dep var pinned latest class changed="" gates=""
    # The staged paths stay global: the EXIT trap fires after this function's
    # locals are gone, and a moved file is a harmless rm -f no-op.
    staged_pins="$(mktemp -t pancake-pins-XXXXXX)"
    staged_sums="$(mktemp -t pancake-checksums-XXXXXX)"
    staged_deno=""
    trap 'rm -f "${staged_pins:-}" "${staged_sums:-}" "${staged_deno:-}"' EXIT
    cp "${dir}/pins.sh" "${staged_pins}"
    cp "${dir}/checksums.sh" "${staged_sums}"

    for dep in "$@"; do
        var="$(dep_var "${dep}")"
        class="$(dep_class "${dep}")"
        if [[ "${class}" == manual ]]; then
            manual_procedure "${dep}"
            return 1
        fi
        pinned="${!var}"
        latest="$(latest_version "${dep}")"
        if [[ -z "${latest}" ]]; then
            echo "update-pins: ${dep}: upstream query failed" >&2
            return 2
        fi
        if [[ "${latest}" == "${pinned}" ]]; then
            echo "${dep}: already ${pinned}"
            continue
        fi
        if [[ "${dep}" == zig ]]; then
            # zls releases follow zig; both pins move together or not at all.
            if ! fetch "https://api.github.com/repos/zigtools/zls/releases/tags/${latest}" >/dev/null 2>&1; then
                echo "update-pins: zig ${latest} is out but zls has no ${latest} release yet; holding both" >&2
                return 1
            fi
            replace_pin_line "${staged_pins}" ZLS_VERSION "${latest}"
        fi
        if [[ "${dep}" == playwright ]]; then
            # The root deno.json resolves the browser proofs' playwright import
            # from the same number; source-check fails if the two disagree.
            staged_deno="$(mktemp -t pancake-denojson-XXXXXX)"
            sed "s|npm:playwright@${pinned}|npm:playwright@${latest}|" \
                "${dir}/../deno.json" > "${staged_deno}"
            grep -q "npm:playwright@${latest}" "${staged_deno}" || {
                echo "update-pins: playwright import not found in deno.json" >&2
                return 1
            }
        fi
        replace_pin_line "${staged_pins}" "${var}" "${latest}"
        refresh_hashes "${dep}" "${latest}" "${staged_sums}"
        changed="${changed}${changed:+, }${dep} ${pinned} -> ${latest}"
        gates="${gates}  - $(dep_gate "${dep}")"$'\n'
        echo "${dep}: ${pinned} -> ${latest}"
    done

    if [[ -z "${changed}" ]]; then
        echo "nothing to do"
        return 0
    fi

    # Validate the staged files whole before any of them land.
    bash -n "${staged_pins}"
    bash -n "${staged_sums}"
    (
        source "${dir}/lib.sh"
        # shellcheck disable=SC1090
        source "${staged_sums}"
        # shellcheck disable=SC1090
        source "${staged_pins}"
        pancake_devcontainer_validate_pins
    )
    # Checksums land first: an unused hash is inert, a version without its
    # hash is not.
    mv "${staged_sums}" "${dir}/checksums.sh"
    mv "${staged_pins}" "${dir}/pins.sh"
    if [[ -n "${staged_deno}" ]]; then
        mv "${staged_deno}" "${dir}/../deno.json"
    fi

    echo
    echo "pins updated: ${changed}"
    echo "rebuild to adopt (bash .devcontainer/up.sh --rebuild), then:"
    printf '%s' "${gates}" | sort -u
}

# ---------------------------------------------------------------------------

case "${1:-check}" in
    check) run_check ;;
    bump)
        shift
        [[ $# -gt 0 ]] || {
            usage >&2
            exit 2
        }
        if [[ "$1" == --safe ]]; then
            safe_deps=()
            for dep in ${ALL_DEPS}; do
                [[ "$(dep_class "${dep}")" == safe ]] && safe_deps+=("${dep}")
            done
            run_bump "${safe_deps[@]}"
        else
            for dep in "$@"; do dep_var "${dep}" >/dev/null || exit 2; done
            run_bump "$@"
        fi
        ;;
    -h | --help) usage ;;
    *)
        usage >&2
        exit 2
        ;;
esac
