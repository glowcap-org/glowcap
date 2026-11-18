# shellcheck shell=bash
# A proof uses the Bend release and its kernel compiled by the matching Lean.
# CI restores only archives. Verify each one before extracting it.
glowcap_tools_bend_unpack() {
    local repo="$1" version="$2" archive="$3" digest="$4" dest="$5" stage="$6" python="$7"
    local cache="${GLOWCAP_CACHE_DIR}/proof-archives"
    mkdir -p "${cache}" "${dest}" || return 1
    if [[ ! -f "${cache}/${archive}" ]] || ! glowcap_verify_sha256 "${cache}/${archive}" "${digest}"; then
        glowcap_fetch_verified "https://github.com/${repo}/releases/download/v${version}/${archive}" \
            "${stage}/${archive}" "${digest}" || return 1
        mv -f "${stage}/${archive}" "${cache}/${archive}" || return 1
    fi
    "${python}" -m tarfile --filter data -e "${cache}/${archive}" "${dest}"
}

glowcap_tools_bend_download() {
    local install="$2" stage bend_arch lean_arch lean_bin python
    stage="$(dirname "${install}")"
    bend_arch="$(glowcap_pick_by_arch bend x64 arm64)" || return 1
    lean_arch="$(glowcap_pick_by_arch lean linux linux_aarch64)" || return 1
    # The image's pinned Python reads Lean's .tar.zst without an extra utility.
    python="$(uv python find --managed-python "${PYTHON_VERSION}")" || return 1
    glowcap_tools_bend_unpack bendlang/bend "${BEND_VERSION}" "bend-${BEND_VERSION}-linux-${bend_arch}.tar.gz" \
        "$(bend_sha256)" "${install}" "${stage}" "${python}" || return 1
    glowcap_tools_bend_unpack leanprover/lean4 "${LEAN_VERSION}" "lean-${LEAN_VERSION}-${lean_arch}.tar.zst" \
        "$(lean_sha256)" "${stage}" "${stage}" "${python}" || return 1
    lean_bin="${stage}/lean-${LEAN_VERSION}-${lean_arch}/bin"
    glowcap_tools_expect_version lean "Lean (version ${LEAN_VERSION},*" "${lean_bin}/lean" || return 1
    # Compile Bend's release kernel as its --verdict bootstrap does. Lean and
    # the intermediate C file leave with the staging directory.
    (cd "${install}/bend/bend2" && "${lean_bin}/lean" -c "${stage}/bendtt.c" bendtt.lean) || return 1
    "${lean_bin}/leanc" -O3 -DNDEBUG "${stage}/bendtt.c" -o "${install}/bendtt" || return 1
    glowcap_tools_record "bendlang/bend@v${BEND_VERSION},leanprover/lean4@v${LEAN_VERSION}" pinned-sha256
}

glowcap_tools_bend_verify() {
    local help
    help="$("$1/bend/bin/bend" --help)" || return 1
    [[ "${help}" == "Bend ${BEND_VERSION}:"* && -x "$1/bendtt" ]]
}

glowcap_tools_bend_exec_path() {
    [[ -x "$1/bendtt" ]] || return 1
    printf '%s\n' "$1/bend/bin/bend"
}

glowcap_tools_bend_exec_env() {
    printf '%s\n' "PATH=$1/bend/bin:${PATH}" "BENDTT=$1/bendtt"
}
