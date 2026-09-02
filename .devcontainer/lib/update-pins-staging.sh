# shellcheck shell=bash
# Staged edits to pins.sh and checksums.sh. Each helper rewrites one shape in
# a staged copy and fails if the anchor it expects is missing, so a drifted
# file shape aborts the bump instead of silently editing nothing.

# Move a staged copy over the file it was built from. mktemp creates its file
# at 0600, so a plain mv would hand the destination the staging mode: that is
# how checksums.sh became owner-only, and the image build COPYs it. Carry the
# destination's own mode across instead, because a version bump has no business
# deciding who can read a pin. Every caller staged from the destination, so it
# is always there to read the mode from.
glowcap_pins_install() {
    local staged="$1" destination="$2"
    chmod --reference="${destination}" "${staged}"
    mv "${staged}" "${destination}"
}

glowcap_pins_replace_line() {
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

glowcap_pins_zls_source_version() {
    local revision="$1"
    glowcap_pins_fetch "https://raw.githubusercontent.com/zigtools/zls/${revision}/build.zig.zon" \
        | awk -F'"' '/\.version = / { print $2; found = 1; exit } END { if (!found) exit 3 }'
}

glowcap_pins_stage_zls_source() {
    local file="$1" revision="$2" version hash
    version="$(glowcap_pins_zls_source_version "${revision}")"
    hash="$(glowcap_pins_url_sha256 "https://github.com/zigtools/zls/archive/${revision}.tar.gz")"
    glowcap_pins_require_hex64 "zls source ${revision}" "${hash}"
    glowcap_pins_replace_line "${file}" ZLS_VERSION "${version}"
    glowcap_pins_replace_line "${file}" ZLS_SOURCE_REVISION "${revision}"
    glowcap_pins_replace_line "${file}" ZLS_SOURCE_SHA256 "${hash}"
}

# Rewrite the two hash lines of a glowcap_pick_by_arch checksum function: x86_64
# value, then aarch64.
glowcap_pins_replace_arch_hashes() {
    local file="$1" fn="$2" x86="$3" a64="$4" tmp="$1.edit"
    glowcap_pins_require_hex64 "${fn} x86_64" "${x86}"
    glowcap_pins_require_hex64 "${fn} aarch64" "${a64}"
    awk -v fn="${fn}" -v x86="${x86}" -v a64="${a64}" '
        n > 0 {
            indent = $0; sub(/[^ ].*$/, "", indent)
            if (n == 2) print indent "\"" x86 "\" \\"
            else print indent "\"" a64 "\""
            n--; next
        }
        $0 ~ ("glowcap_pick_by_arch " fn " \\\\$") { print; n = 2; found = 1; next }
        { print }
        END { if (!found || n != 0) exit 3 }
    ' "${file}" > "${tmp}" || {
        echo "update-pins: glowcap_pick_by_arch ${fn} block not found in checksums.sh" >&2
        rm -f "${tmp}"
        return 1
    }
    mv "${tmp}" "${file}"
}

# Rewrite one platform arm of zig_sha256's OS-arch case.
glowcap_pins_replace_zig_hash() {
    local file="$1" key="$2" hash="$3" tmp="$1.edit"
    glowcap_pins_require_hex64 "zig ${key}" "${hash}"
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
glowcap_pins_refresh_hashes() {
    local dep="$1" version="$2" file="$3"
    case "${dep}" in
        zig)
            local index
            index="$(glowcap_pins_fetch https://ziglang.org/download/index.json)"
            local key platform hash
            while read -r key platform; do
                hash="$(jq -r --arg v "${version}" --arg p "${platform}" \
                    'if .master.version == $v then .master[$p].shasum else .[$v][$p].shasum end // empty' <<< "${index}")"
                if [[ -z "${hash}" ]]; then
                    echo "update-pins: zig index has no ${platform} for ${version}" >&2
                    return 1
                fi
                glowcap_pins_replace_zig_hash "${file}" "${key}" "${hash}"
            done <<'EOF'
Linux-x86_64 x86_64-linux
Linux-aarch64 aarch64-linux
Darwin-arm64 aarch64-macos
Darwin-x86_64 x86_64-macos
EOF
            ;;
        rustup-init)
            local base="https://static.rust-lang.org/rustup/archive/${version}"
            glowcap_pins_replace_arch_hashes "${file}" rustup_init_sha256 \
                "$(glowcap_pins_fetch "${base}/x86_64-unknown-linux-gnu/rustup-init.sha256" | cut -d' ' -f1)" \
                "$(glowcap_pins_fetch "${base}/aarch64-unknown-linux-gnu/rustup-init.sha256" | cut -d' ' -f1)"
            ;;
        deno)
            glowcap_pins_replace_arch_hashes "${file}" deno_sha256 \
                "$(glowcap_pins_github_asset_sha256 denoland/deno "v${version}" deno-x86_64-unknown-linux-gnu.zip)" \
                "$(glowcap_pins_github_asset_sha256 denoland/deno "v${version}" deno-aarch64-unknown-linux-gnu.zip)"
            ;;
        node)
            local sums
            sums="$(glowcap_pins_fetch "https://nodejs.org/dist/v${version}/SHASUMS256.txt")"
            glowcap_pins_replace_arch_hashes "${file}" node_sha256 \
                "$(awk -v f="node-v${version}-linux-x64.tar.xz" '$2 == f { print $1 }' <<< "${sums}")" \
                "$(awk -v f="node-v${version}-linux-arm64.tar.xz" '$2 == f { print $1 }' <<< "${sums}")"
            ;;
        bun)
            glowcap_pins_replace_arch_hashes "${file}" bun_sha256 \
                "$(glowcap_pins_github_asset_sha256 oven-sh/bun "bun-v${version}" bun-linux-x64.zip)" \
                "$(glowcap_pins_github_asset_sha256 oven-sh/bun "bun-v${version}" bun-linux-aarch64.zip)"
            ;;
        uv)
            glowcap_pins_replace_arch_hashes "${file}" uv_sha256 \
                "$(glowcap_pins_github_asset_sha256 astral-sh/uv "${version}" uv-x86_64-unknown-linux-gnu.tar.gz)" \
                "$(glowcap_pins_github_asset_sha256 astral-sh/uv "${version}" uv-aarch64-unknown-linux-gnu.tar.gz)"
            ;;
        cursor-agent)
            local cursor_base="https://downloads.cursor.com/lab/${version}/linux"
            glowcap_pins_replace_arch_hashes "${file}" cursor_agent_sha256 \
                "$(glowcap_pins_url_sha256 "${cursor_base}/x64/agent-cli-package.tar.gz")" \
                "$(glowcap_pins_url_sha256 "${cursor_base}/arm64/agent-cli-package.tar.gz")"
            ;;
        opencode)
            glowcap_pins_replace_arch_hashes "${file}" opencode_sha256 \
                "$(glowcap_pins_github_asset_sha256 sst/opencode "v${version}" opencode-linux-x64.tar.gz)" \
                "$(glowcap_pins_github_asset_sha256 sst/opencode "v${version}" opencode-linux-arm64.tar.gz)"
            ;;
    esac
}
