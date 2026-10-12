# shellcheck shell=bash
# OpenCode driver: the exact platform archive, checksummed from checksums.sh
# for seeds and from the GitHub release's published asset digest for
# upstream updates. Where upstream publishes no digest,
# glowcap_pins_github_asset_sha256 hashes a fetched copy, and the receipt's
# upstream-digest label covers both bases.
#
# Update ownership: the process runs with OPENCODE_DISABLE_AUTOUPDATE=1. The
# native `opencode upgrade` replaces its own binary in place, which breaks
# install immutability, so a bare `upgrade` routes to the front and its
# options are refused; `uninstall` would remove an install other containers
# share and is refused outright.

glowcap_tools_opencode_download() {
    local version="$1" install_dir="$2" policy="$3"
    local arch tarball url expected verification tmp rc=0
    arch="$(glowcap_pick_by_arch opencode x64 arm64)" || return 1
    tarball="opencode-linux-${arch}.tar.gz"
    url="https://github.com/sst/opencode/releases/download/v${version}/${tarball}"
    if [[ "${policy}" == seed ]]; then
        expected="$(opencode_sha256)" || return 1
        verification=checksum
    else
        expected="$(glowcap_pins_github_asset_sha256 sst/opencode "v${version}" "${tarball}")" || {
            echo "opencode driver: no digest available for the upstream asset" >&2
            return 1
        }
        verification=upstream-digest
    fi
    mkdir -p "${install_dir}" || return 1
    tmp="$(mktemp -t glowcap-opencode-XXXXXX)" || return 1
    glowcap_fetch_verified "${url}" "${tmp}" "${expected}" || rc=1
    if [[ "${rc}" -eq 0 ]]; then
        tar -xzf "${tmp}" -C "${install_dir}" </dev/null || rc=1
    fi
    rm -f "${tmp}"
    if [[ "${rc}" -ne 0 || ! -x "${install_dir}/opencode" ]]; then
        echo "opencode driver: install of ${version} did not produce ${install_dir}/opencode" >&2
        return 1
    fi
    glowcap_tools_record "${url}" "${verification}" "${expected}" "${expected}"
}

glowcap_tools_opencode_verify() {
    glowcap_tools_expect_version opencode "$2*" "$1/opencode"
}

glowcap_tools_opencode_exec_path() {
    printf '%s\n' "$1/opencode"
}

glowcap_tools_opencode_exec_env() {
    printf '%s\n' "OPENCODE_DISABLE_AUTOUPDATE=1"
}

glowcap_tools_opencode_intercept() {
    case "${1:-}" in
        upgrade) glowcap_tools_intercept_verb opencode "$@" ;;
        uninstall) printf 'refuse:opencode uninstall would remove an installation other containers may use; removal is not a managed operation\n' ;;
        *) printf 'pass\n' ;;
    esac
}
