# shellcheck shell=bash
# A proof uses the Bend release and its kernel compiled by the matching Lean.
glowcap_tools_bend_download() {
    local install="$2" stage bend lean lean_bin python
    stage="$(dirname "${install}")"
    bend="bend-${BEND_VERSION}-linux-$(glowcap_pick_by_arch bend x64 arm64).tar.gz" || return 1
    lean="lean-${LEAN_VERSION}-$(glowcap_pick_by_arch lean linux linux_aarch64)" || return 1
    mkdir -p "${install}" || return 1
    glowcap_fetch_verified "https://github.com/bendlang/bend/releases/download/v${BEND_VERSION}/${bend}" \
        "${stage}/${bend}" "$(bend_sha256)" || return 1
    glowcap_fetch_verified "https://github.com/leanprover/lean4/releases/download/v${LEAN_VERSION}/${lean}.tar.zst" \
        "${stage}/${lean}.tar.zst" "$(lean_sha256)" || return 1
    # The image's pinned Python reads Lean's .tar.zst without an extra utility.
    python="$(uv python find --managed-python "${PYTHON_VERSION}")" || return 1
    "${python}" -m tarfile --filter data -e "${stage}/${bend}" "${install}" || return 1
    "${python}" -m tarfile --filter data -e "${stage}/${lean}.tar.zst" "${stage}" || return 1
    lean_bin="${stage}/${lean}/bin"
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
