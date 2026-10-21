# shellcheck shell=bash
# Cursor agent CLI driver: the exact platform archive, kept whole (its
# launcher resolves the bundled node and helpers relative to its own
# realpath). Seeds are checksummed from checksums.sh. Cursor publishes no
# version index and no asset digest, so an upstream update is fetched over
# HTTPS and its received digest recorded: provenance, not authenticity.
#
# Update ownership: the shipped auto-update gate is
# `disableAutoUpdate || channel === "static"`, reachable through the
# top-level option --disable-auto-update. Every exec prepends it, and verify
# refuses a build that does not accept it. The native `update` verb routes
# to the front.

glowcap_tools_cursor_agent_download() {
    local version="$1" install_dir="$2" policy="$3"
    local arch url tmp rc=0 expected="" observed verification
    arch="$(glowcap_pick_by_arch cursor-agent x64 arm64)" || return 1
    url="https://downloads.cursor.com/lab/${version}/linux/${arch}/agent-cli-package.tar.gz"
    mkdir -p "${install_dir}" || return 1
    tmp="$(mktemp -t glowcap-cursor-agent-XXXXXX)" || return 1
    if [[ "${policy}" == seed ]]; then
        verification=checksum
        if ! expected="$(cursor_agent_sha256)" ||
            ! glowcap_fetch_verified "${url}" "${tmp}" "${expected}" </dev/null; then
            rc=1
        fi
    else
        verification=tls-recorded
        curl --fail --location --silent --show-error --output "${tmp}" "${url}" </dev/null || rc=1
    fi
    if [[ "${rc}" -eq 0 ]]; then
        observed="$(sha256sum "${tmp}" | cut -d' ' -f1)" || rc=1
    fi
    if [[ "${rc}" -eq 0 ]]; then
        tar -xzf "${tmp}" -C "${install_dir}" --strip-components=1 </dev/null || rc=1
    fi
    rm -f "${tmp}"
    if [[ "${rc}" -ne 0 || ! -x "${install_dir}/cursor-agent" ]]; then
        echo "cursor-agent driver: install of ${version} did not produce ${install_dir}/cursor-agent" >&2
        return 1
    fi
    glowcap_tools_record "${url}" "${verification}" "${expected}" "${observed}"
}

glowcap_tools_cursor_agent_verify() {
    glowcap_tools_expect_version cursor-agent "$2*" "$1/cursor-agent" || return 1
    # The exec prepends --disable-auto-update; a build that no longer accepts status-allow: lifecycle transition
    # the flag must not be published, or every invocation would break.
    if ! glowcap_tools_isolated "$1/cursor-agent" --disable-auto-update --help >/dev/null 2>&1; then
        echo "cursor-agent driver: build rejects --disable-auto-update; refusing the install" >&2
        return 1
    fi
}

glowcap_tools_cursor_agent_exec_path() {
    printf '%s\n' "$1/cursor-agent"
}

glowcap_tools_cursor_agent_argv_prefix() {
    printf '%s\n' "--disable-auto-update"
}

# Cursor versions are <date>-<commit>. Dates order; commit hashes on one
# date have no chronological order, so a same-day build is never newer, and
# an explicit update may adopt it.
glowcap_tools_cursor_agent_version_newer() {
    local a="$1" b="$2" shape='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]+$'
    if [[ "${a}" =~ ${shape} && "${b}" =~ ${shape} ]]; then
        a="${a%%-*}"
        b="${b%%-*}"
    fi
    glowcap_tools_default_version_newer "${a}" "${b}"
}

glowcap_tools_cursor_agent_intercept() {
    case "${1:-}" in
        update) glowcap_tools_intercept_verb cursor-agent "$@" ;;
        *) printf 'pass\n' ;;
    esac
}
