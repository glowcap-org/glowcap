# shellcheck shell=bash
# The shared installation lifecycle for managed tools: where installs live,
# how a version is chosen, and the ensure / update / repair / status verbs.
#
# Runs only inside the devcontainer, on Linux: it needs flock (util-linux),
# GNU sort -V and ln -r, and a current Bash. Callers assert the side and load
# lib/mod.sh (pins) plus lib/update-pins-deps.sh (validated release queries)
# before sourcing this file.
#
# Layout, under ${GLOWCAP_CACHE_DIR}/installed/<platform>/<tool>, shared by
# every worktree container through the ~/.cache/glowcap bind:
#
#   current                       seed policy: relative link to one install
#   required/<requirement>        pinned policy: one link per exact requirement
#   installs/<version>-<id>/      one complete, immutable, verified install
#   installs/<...>/receipt        receipt: fixed KEY=VALUE data, never sourced
#   .staging-<id>/                private work in progress, removed on exit
#   lock                          stable flock target; never replaced/deleted
#
# The platform key is linux-<uname -m>; lib/settings.sh owns it.
# GLOWCAP_TOOLS_CACHE_ROOT overrides the root for tests, which must not write
# the shared cache.
#
# Publication (the lock spans state re-read through publication): stage in a
# random directory on the same filesystem; the driver fills and verifies it;
# a reported expected digest must equal the observed one; the receipt is
# written; the rename into installs/ is the commit point; the install is made
# read-only and verified again from its final path; a temporary relative link
# is renamed over the selection. A failed or interrupted operation leaves the
# previous selection untouched and removes only its own staging directory. A
# racing container's completed install is adopted, never repeated. Superseded
# installs stay until removed by hand: a process in another container may
# still be running from one.
#
# Ordering: only harness updates compare versions, with LC_ALL=C sort -V. A
# driver may override version_newer when its versions carry no chronological
# order (cursor's same-day builds). Equality is never newer.
#
# Exit codes: 1 install/verification failure, 2 upstream-query failure,
# 64 invalid usage, 75 lock contention. Forwarded tools keep their own.

# ---------------------------------------------------------------------------
# Driver contract. One file per tool in this directory, named after the tool.
# Every driver defines, prefixed glowcap_tools_<ident>_:
#
#   download <version> <install-dir> <policy>
#       Fill <install-dir> with a complete install of exactly <version>.
#       policy is seed (verified against pins.sh and checksums.sh), upstream
#       (verified against the upstream-published digest where one exists;
#       otherwise the received digest is recorded, which is provenance, not
#       authenticity), or pinned (the checkout's exact requirement). The
#       lifecycle has already refused a policy the tool's registry row does
#       not allow. Installers read closed stdin and write to stderr. Report
#       provenance with glowcap_tools_record.
#   verify <install-dir> <version>
#       Exit zero when the install answers exactly <version>, with isolated
#       state (glowcap_tools_expect_version). Called in conditional contexts.
#   exec_path <install-dir>
#       Print the absolute path of the binary to exec.
#   exec_env [install-dir]
#       Optional. Print KEY=VALUE lines applied to the exec: the switches that
#       hand update ownership to this lifecycle, or the paths a consuming
#       process needs.
#   argv_prefix <install-dir>
#       Optional. Print words prepended to every exec.
#   intercept <args...>
#       Optional (default pass). Classify an invocation: print `pass`, `update`, `help`, or
#       `refuse:<message>`. Only a bare lifecycle verb as the first argument
#       is intercepted (glowcap_tools_intercept_verb).
#   version_newer <candidate> <current>
#       Optional ordering override.
# ---------------------------------------------------------------------------

glowcap_tools_cache_root() {
    printf '%s\n' "${GLOWCAP_TOOLS_CACHE_ROOT:-${GLOWCAP_CACHE_DIR}/installed}"
}

glowcap_tools_install_dir() {
    printf '%s\n' "$(glowcap_tools_cache_root)/$(glowcap_devcontainer_tools_platform)/$1"
}

glowcap_tools_random_id() {
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
}

# The link a tool's policy publishes: `current` for seed-policy tools, and
# `required/<requirement>` for pinned-policy tools, so two checkouts on
# different exact requirements keep their own selections in one cache.
glowcap_tools_selection_link() {
    local tool="$1" requirement="${2:-}"
    if [[ "$(glowcap_tools_policy "${tool}")" == pinned ]]; then
        printf '%s\n' "$(glowcap_tools_install_dir "${tool}")/required/${requirement:-$(glowcap_tools_seed "${tool}")}"
    else
        printf '%s\n' "$(glowcap_tools_install_dir "${tool}")/current"
    fi
}

# The install the selection link names, or nothing ("not installed"). The
# target must be a directory under this tool's installs/; anything else is
# malformed, not merely absent.
glowcap_tools_selected_dir() {
    local tool="$1" link installs resolved
    link="$(glowcap_tools_selection_link "${tool}")"
    if [[ -e "${link}" && ! -L "${link}" ]]; then
        echo "tools: ${tool}: '${link##*/}' is a real directory, not a selection link; run: bash .devcontainer/bin/tools.sh repair ${tool}" >&2
        return 1
    fi
    [[ -L "${link}" ]] || return 0
    resolved="$(readlink -f "${link}")" || return 1
    installs="$(readlink -f "$(glowcap_tools_install_dir "${tool}")")/installs/"
    if [[ "${resolved}" != "${installs}"* ]]; then
        echo "tools: ${tool}: selection link escapes this tool's installs/ directory; run: bash .devcontainer/bin/tools.sh repair ${tool}" >&2
        return 1
    fi
    printf '%s\n' "${resolved}"
}

# Validate one published install structurally: a parseable receipt naming
# this tool, and the driver's executable present. No tool is run.
glowcap_tools_validate_install() {
    local tool="$1" install_dir="$2" exec_path receipt_tool
    [[ -d "${install_dir}" ]] || return 1
    receipt_tool="$(glowcap_tools_receipt_field "${install_dir}" tool)" || return 1
    if [[ "${receipt_tool}" != "${tool}" ]]; then
        echo "tools: ${tool}: receipt in ${install_dir} names tool '${receipt_tool}'" >&2
        return 1
    fi
    exec_path="$(glowcap_tools_dispatch "${tool}" exec_path "${install_dir}")" || return 1
    [[ -n "${exec_path}" && -x "${exec_path}" ]] || {
        echo "tools: ${tool}: executable ${exec_path:-<none>} is missing or not executable in ${install_dir}" >&2
        return 1
    }
}

# Read one field from a receipt. The receipt is data, never shell source.
glowcap_tools_receipt_field() {
    local install_dir="$1" field="$2" value
    [[ -f "${install_dir}/receipt" ]] || return 1
    value="$(grep -m1 "^${field}=" "${install_dir}/receipt" | cut -d= -f2-)" || return 1
    [[ -n "${value}" ]] || return 1
    printf '%s\n' "${value}"
}

# The provenance a driver's download reports for the receipt:
#   <source> <verification> [expected-sha256] [observed-sha256]
glowcap_tools_record() {
    GLOWCAP_TOOLS_SOURCE_URL="$1"
    GLOWCAP_TOOLS_VERIFICATION="$2"
    GLOWCAP_TOOLS_EXPECTED_SHA="${3:-}"
    GLOWCAP_TOOLS_OBSERVED_SHA="${4:-}"
}

# <install-dir> <package@version> [npm options...]: an exact npm package
# installed with global semantics into a redirected prefix (npm refuses
# --allow-scripts on project-scoped installs), so the install relocates
# whole. Registry integrity verifies the download; it is registry metadata,
# not an independent signature.
glowcap_tools_npm_install() {
    local install_dir="$1" spec="$2"
    shift 2
    if ! npm install -g --prefix "${install_dir}" --no-fund --no-audit "$@" "${spec}" </dev/null >&2; then
        echo "tools: npm install of ${spec} failed" >&2
        return 1
    fi
    glowcap_tools_record "npm:${spec}" registry-integrity
}

# Run <command...> with every harness state location pointed into a private
# scratch directory, so a version probe never reads or writes a real login.
glowcap_tools_isolated() {
    local scratch rc=0
    scratch="$(mktemp -d)" || return 1
    HOME="${scratch}" XDG_CONFIG_HOME="${scratch}/config" XDG_DATA_HOME="${scratch}/data" \
        XDG_CACHE_HOME="${scratch}/cache" CLAUDE_CONFIG_DIR="${scratch}/claude" \
        CODEX_HOME="${scratch}/codex" CURSOR_CONFIG_DIR="${scratch}/cursor" \
        CURSOR_DATA_DIR="${scratch}/cursor-data" "$@" || rc=$?
    rm -rf "${scratch}"
    return "${rc}"
}

# <tool> <glob> <command...>: the command's `--version` output, run isolated,
# must match <glob>.
glowcap_tools_expect_version() {
    local tool="$1" glob="$2" output
    shift 2
    if ! output="$(glowcap_tools_isolated "$@" --version 2>&1)"; then
        echo "${tool} driver: --version failed: ${output}" >&2
        return 1
    fi
    # shellcheck disable=SC2053  # the right side is the caller's glob
    if [[ "${output}" != ${glob} ]]; then
        echo "${tool} driver: expected ${glob} in: ${output}" >&2
        return 1
    fi
}

# <tool> <verb> <args after the verb...>: the classification of a native
# lifecycle verb this lifecycle owns. Bare routes to the front, help explains,
# and any option is refused rather than dropped.
glowcap_tools_intercept_verb() {
    local tool="$1" verb="$2"
    shift 2
    if [[ $# -eq 0 ]]; then
        printf 'update\n'
    elif [[ "$1" == -h || "$1" == --help ]]; then
        printf 'help\n'
    else
        printf 'refuse:%s %s options are managed by .devcontainer/bin/tools.sh update %s\n' "${tool}" "${verb}" "${tool}"
    fi
}

glowcap_tools_default_version_newer() {
    local a="$1" b="$2"
    [[ "${a}" != "${b}" ]] || return 1
    [[ "$(LC_ALL=C printf '%s\n%s\n' "${a}" "${b}" | sort -V | tail -n 1)" == "${a}" ]]
}

glowcap_tools_default_argv_prefix() {
    :
}

glowcap_tools_default_exec_env() {
    :
}

glowcap_tools_default_intercept() {
    printf 'pass\n'
}

# Call a driver hook, falling back to the default when the driver does not
# define it.
glowcap_tools_dispatch() {
    local tool="$1" fn="$2" ident
    ident="$(glowcap_tools_ident "${tool}")"
    if declare -F "glowcap_tools_${ident}_${fn}" >/dev/null; then
        "glowcap_tools_${ident}_${fn}" "${@:3}"
    else
        "glowcap_tools_default_${fn}" "${@:3}"
    fi
}

# Explicit update adoption: a different version that is not older.
glowcap_tools_adopts() {
    local tool="$1" candidate="$2" current="$3"
    [[ "${candidate}" != "${current}" ]] || return 1
    ! glowcap_tools_dispatch "${tool}" version_newer "${current}" "${candidate}"
}

# Acquire the tool's maintenance lock on descriptor 9. The lock file's inode
# is never replaced or deleted. A bounded wait reports contention and the
# retry command instead of queueing forever.
glowcap_tools_lock() {
    local tool="$1" lock_dir
    lock_dir="$(glowcap_tools_install_dir "${tool}")"
    mkdir -p "${lock_dir}" || return 1
    exec 9>>"${lock_dir}/lock" || return 1
    if ! flock -w "${GLOWCAP_TOOLS_LOCK_WAIT:-120}" 9; then
        exec 9>&-
        echo "tools: ${tool}: another maintenance operation holds the lock; retry: bash .devcontainer/bin/tools.sh ${GLOWCAP_TOOLS_RETRY_VERB:-ensure} ${tool}" >&2
        return 75
    fi
}

glowcap_tools_unlock() {
    flock -u 9 2>/dev/null || true
    exec 9>&- 2>/dev/null || true
}

# Install one version with the lock already held.
#   $1 tool  $2 version  $3 policy (seed | upstream | pinned)
glowcap_tools_install() {
    local tool="$1" version="$2" policy="$3"
    local tool_dir staging rc=0 install_name existing
    if [[ ! "${version}" =~ ^[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]]; then
        echo "tools: ${tool}: refusing unusable version string: ${version}" >&2
        return 64
    fi
    case "$(glowcap_tools_policy "${tool}"):${policy}" in
        seed:seed | seed:upstream | pinned:pinned) ;;
        *)
            echo "tools: ${tool}: install policy '${policy}' does not fit its registry policy" >&2
            return 64
            ;;
    esac
    tool_dir="$(glowcap_tools_install_dir "${tool}")"
    mkdir -p "${tool_dir}/installs" || return 1

    # Adopt an existing complete install of the same version (a racing
    # container's rename or this repair's earlier success). Installs that status-allow: event or source ordering
    # fail validation are skipped, never trusted.
    for existing in "${tool_dir}/installs/${version}"-*; do
        [[ -e "${existing}" ]] || continue
        if glowcap_tools_validate_install "${tool}" "${existing}"; then
            glowcap_tools_link_selection "${tool}" "${existing}" "${version}"
            return
        fi
    done

    staging="$(mktemp -d "${tool_dir}/.staging-XXXXXXXX")" || return 1
    glowcap_tools_record "" ""
    # Staging is this operation's own; signals clean it and re-raise.
    trap 'rm -rf "${staging:-}"' EXIT
    trap 'chmod -R u+w "${staging:-}" 2>/dev/null; rm -rf "${staging:-}"; trap - INT; kill -INT $$' INT
    trap 'chmod -R u+w "${staging:-}" 2>/dev/null; rm -rf "${staging:-}"; trap - TERM; kill -TERM $$' TERM

    # The download may spawn long children; they must not inherit the lock
    # descriptor, or an orphaned child would hold the lock after a kill.
    # Installation cannot consume input intended for the eventual tool.
    glowcap_tools_dispatch "${tool}" download "${version}" "${staging}/install" "${policy}" </dev/null >&2 9>&- || rc=1
    if [[ "${rc}" -eq 0 && -n "${GLOWCAP_TOOLS_EXPECTED_SHA}" && -n "${GLOWCAP_TOOLS_OBSERVED_SHA}" &&
        "${GLOWCAP_TOOLS_EXPECTED_SHA}" != "${GLOWCAP_TOOLS_OBSERVED_SHA}" ]]; then
        echo "tools: ${tool}: downloaded bytes do not match the expected digest for ${version}" >&2
        rc=1
    fi
    if [[ "${rc}" -eq 0 ]]; then
        glowcap_tools_dispatch "${tool}" verify "${staging}/install" "${version}" || rc=1
    fi
    if [[ "${rc}" -ne 0 ]]; then
        echo "tools: ${tool}: install of ${version} failed; the previous selection is unchanged" >&2
        return 1
    fi

    cat > "${staging}/install/receipt" <<EOF || rc=1
schema=1
tool=${tool}
version=${version}
requirement=${version}
platform=$(glowcap_devcontainer_tools_platform)
policy=${policy}
source=${GLOWCAP_TOOLS_SOURCE_URL:--}
verification=${GLOWCAP_TOOLS_VERIFICATION:--}
expected_sha256=${GLOWCAP_TOOLS_EXPECTED_SHA:--}
observed_sha256=${GLOWCAP_TOOLS_OBSERVED_SHA:--}
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    # A unique identity lets repair publish the same version again without
    # touching files a running process still uses. The rename is the commit
    # point; renaming across parents needs write on the directory itself, so
    # immutability is applied after it lands.
    install_name="${version}-$(glowcap_tools_random_id)"
    if [[ "${rc}" -eq 0 ]]; then
        mv "${staging}/install" "${tool_dir}/installs/${install_name}" || rc=1
    fi
    rm -rf "${staging}" 2>/dev/null || { chmod -R u+w "${staging}" 2>/dev/null; rm -rf "${staging}"; }
    if [[ "${rc}" -eq 0 ]]; then
        chmod -R a-w "${tool_dir}/installs/${install_name}" || rc=1
    fi
    [[ "${rc}" -eq 0 ]] || return 1
    trap - EXIT INT TERM
    # Relocation check: npm prefixes and launchers may embed paths that break
    # after the move, so the published path must answer too.
    if ! glowcap_tools_dispatch "${tool}" verify "${tool_dir}/installs/${install_name}" "${version}"; then
        echo "tools: ${tool}: ${version} failed verification from its published path; run: bash .devcontainer/bin/tools.sh repair ${tool}" >&2
        return 1
    fi
    glowcap_tools_link_selection "${tool}" "${tool_dir}/installs/${install_name}" "${version}"
}

# Install the checkout's seed (seed policy) or exact requirement (pinned
# policy), with the lock already held.
glowcap_tools_install_seed() {
    glowcap_tools_install "$1" "$(glowcap_tools_seed "$1")" "$(glowcap_tools_policy "$1")"
}

# Publish one install as the policy's selection atomically: a temporary
# relative link renamed over the old one, so a concurrent reader sees one status-allow: replacement state identity
# answer or the other. The requirement recorded with the install names a
# pinned link, so a repair keeps the requirement it was installed for even
# after the checkout's pin moves.
glowcap_tools_link_selection() {
    local tool="$1" install="$2" requirement="$3" link tmp
    link="$(glowcap_tools_selection_link "${tool}" "${requirement}")"
    tmp="${link%/*}/.swap-$(glowcap_tools_random_id)"
    mkdir -p "${link%/*}" || return 1
    ln -sr "${install}" "${tmp}" || return 1
    mv -T "${tmp}" "${link}" || {
        rm -f "${tmp}"
        echo "tools: ${tool}: could not publish the selection link ${link}" >&2
        return 1
    }
}

# Explicit maintenance: install the missing seed, adopt a strictly newer
# seed, and verify the selected install. Keeps a newer explicit update; no
# upstream query. The lock spans the state re-read through publication, so
# two concurrent selections cannot publish stale pre-lock decisions.
glowcap_tools_ensure_tool() {
    local tool="$1" seed current current_version rc=0
    seed="$(glowcap_tools_seed "${tool}")"
    glowcap_tools_selected_dir "${tool}" >/dev/null || return 1
    glowcap_tools_lock "${tool}" || return $?
    current="$(glowcap_tools_selected_dir "${tool}")" || current=""
    if [[ -z "${current}" ]]; then
        echo "tools: ${tool}: installing ${seed}" >&2
        glowcap_tools_install_seed "${tool}" || rc=1
    elif [[ "$(glowcap_tools_policy "${tool}")" == seed ]]; then
        current_version="$(glowcap_tools_receipt_field "${current}" version)" || current_version=""
        if glowcap_tools_dispatch "${tool}" version_newer "${seed}" "${current_version}"; then
            echo "tools: ${tool}: adopting seed ${seed} over ${current_version}" >&2
            glowcap_tools_install_seed "${tool}" || rc=1
        fi
    fi
    glowcap_tools_unlock
    [[ "${rc}" -eq 0 ]] || return "${rc}"
    # Prove the selection answers, warm or fresh.
    current="$(glowcap_tools_selected_dir "${tool}")" || return 1
    if [[ -z "${current}" ]]; then
        echo "tools: ${tool}: no selection after ensure" >&2
        return 1
    fi
    glowcap_tools_validate_install "${tool}" "${current}" || return 1
    current_version="$(glowcap_tools_receipt_field "${current}" version)" || current_version=""
    if ! glowcap_tools_dispatch "${tool}" verify "${current}" "${current_version}"; then
        echo "tools: ${tool}: ${current_version} failed its version check; run: bash .devcontainer/bin/tools.sh repair ${tool}" >&2
        return 1
    fi
}

# Move a harness to its upstream latest. The query is the validated release
# channel update-pins.sh reports against, resolved inside the lock so queued
# updates cannot publish stale pre-lock decisions. Explicit adoption may
# accept a different same-day build (driver ordering) but never an older
# release.
glowcap_tools_update_tool() {
    local tool="$1" latest current current_version="" rc=0
    if [[ "$(glowcap_tools_policy "${tool}")" == pinned ]]; then
        echo "tools: ${tool}: its version is owned by bin/update-pins.sh; a pin bump is prepared by tools.sh ensure ${tool}" >&2
        return 64
    fi
    glowcap_tools_lock "${tool}" || return $?
    current="$(glowcap_tools_selected_dir "${tool}")" || current=""
    if ! latest="$(glowcap_pins_latest_version "$(glowcap_tools_dep "${tool}")")"; then
        glowcap_tools_unlock
        echo "tools: ${tool}: upstream query failed; selection unchanged" >&2
        return 2
    fi
    if [[ -n "${current}" ]]; then
        current_version="$(glowcap_tools_receipt_field "${current}" version)" || current_version=""
    fi
    if [[ -z "${current}" ]] || glowcap_tools_adopts "${tool}" "${latest}" "${current_version}"; then
        echo "tools: ${tool}: installing ${latest}" >&2
        glowcap_tools_install "${tool}" "${latest}" upstream || rc=1
    else
        echo "tools: ${tool}: ${current_version} is current (upstream ${latest})" >&2
    fi
    glowcap_tools_unlock
    return "${rc}"
}

# Reinstall the selection into a new immutable install using its recorded
# policy, preserving the old selection until the new one publishes. With no status-allow: replacement state identity
# selection, prepare the seed.
glowcap_tools_repair_tool() {
    local tool="$1" current version policy rc=0
    current="$(glowcap_tools_selected_dir "${tool}")" || return 1
    if [[ -z "${current}" ]]; then
        echo "tools: ${tool}: nothing installed; installing the seed" >&2
        glowcap_tools_ensure_tool "${tool}"
        return
    fi
    version="$(glowcap_tools_receipt_field "${current}" version)" || version=""
    policy="$(glowcap_tools_receipt_field "${current}" policy)" || policy=""
    if [[ -z "${version}" || -z "${policy}" ]]; then
        echo "tools: ${tool}: the selected install has no trustworthy receipt; wipe it by hand and run: bash .devcontainer/bin/tools.sh ensure ${tool}" >&2
        return 1
    fi
    glowcap_tools_lock "${tool}" || return $?
    glowcap_tools_install "${tool}" "${version}" "${policy}" || rc=1
    glowcap_tools_unlock
    return "${rc}"
}

# One line per named tool: selected version, seed, and the selection's
# policy. No network, no tool execution; malformed state is distinct.
glowcap_tools_status() {
    local tool current version policy
    printf '%-14s %-24s %-24s %s\n' TOOL SELECTED SEED POLICY
    for tool in "$@"; do
        version="-"
        policy="-"
        current="$(glowcap_tools_selected_dir "${tool}" 2>/dev/null)" || current=""
        if [[ -n "${current}" ]]; then
            if glowcap_tools_validate_install "${tool}" "${current}" 2>/dev/null; then
                version="$(glowcap_tools_receipt_field "${current}" version)" || version="?"
                policy="$(glowcap_tools_receipt_field "${current}" policy)" || policy="?"
            else
                version="malformed"
            fi
        fi
        printf '%-14s %-24s %-24s %s\n' "${tool}" "${version}" "$(glowcap_tools_seed "${tool}")" "${policy}"
    done
}

# The driver's KEY=VALUE environment for one selected install, as an array
# named by $3.
glowcap_tools_exec_env_lines() {
    local tool="$1" install="$2" line
    local -n into="$3"
    into=()
    while IFS= read -r line; do
        [[ -z "${line}" ]] || into+=("${line}")
    done < <(glowcap_tools_dispatch "${tool}" exec_env "${install}")
}

# Prepare the tool's selection and exec the given command with the driver's
# environment applied. Replaces the calling process, so a pinned asset's
# resolved paths reach the command without a parent that could drop them.
glowcap_tools_exec_command() {
    local tool="$1" env_lines=()
    shift
    glowcap_tools_resolve_exec "${tool}" || return $?
    glowcap_tools_exec_env_lines "${tool}" "${GLOWCAP_TOOLS_SELECTED}" env_lines
    exec env -- "${env_lines[@]}" "$@"
}

# Resolve the concrete executable for an ordinary invocation. A valid
# selection resolves without any lock, network, or tool run; an absent one
# is a cold path that installs the seed under the lock; a malformed one is
# an error naming the remedy. Sets GLOWCAP_TOOLS_SELECTED (the install) and
# GLOWCAP_TOOLS_EXEC (its executable) on success.
glowcap_tools_resolve_exec() {
    local tool="$1" current
    current="$(glowcap_tools_selected_dir "${tool}")" || return 1
    if [[ -z "${current}" ]]; then
        glowcap_tools_lock "${tool}" || return $?
        current="$(glowcap_tools_selected_dir "${tool}")" || current=""
        if [[ -z "${current}" ]]; then
            echo "tools: ${tool}: first use; installing $(glowcap_tools_seed "${tool}")" >&2
            glowcap_tools_install_seed "${tool}" || {
                glowcap_tools_unlock
                return 1
            }
        fi
        glowcap_tools_unlock
        current="$(glowcap_tools_selected_dir "${tool}")" || return 1
    fi
    glowcap_tools_validate_install "${tool}" "${current}" || {
        echo "tools: ${tool}: the selection is malformed; run: bash .devcontainer/bin/tools.sh repair ${tool}" >&2
        return 1
    }
    GLOWCAP_TOOLS_SELECTED="${current}"
    # shellcheck disable=SC2034  # consumed by tools/wrapper.sh
    GLOWCAP_TOOLS_EXEC="$(glowcap_tools_dispatch "${tool}" exec_path "${current}")"
}
