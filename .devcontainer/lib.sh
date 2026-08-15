# shellcheck shell=bash
# Shared helpers for devcontainer install, verify, and config checks. Sourced
# by scripts on both sides of the container boundary, so everything here stays
# portable to the host's bash (macOS ships 3.2).

# Execution-context guards. The devcontainer image exports
# PANCAKE_DEVCONTAINER_DIR (present during its build and in the running
# container), and an attached editor shell or docker exec sees /.dockerenv,
# so "inside the pancake devcontainer or its image build" is decidable from
# either side. Scripts declare their side by calling one of the require
# helpers first thing; a script that may run on both sides calls neither and
# says so in its header.
pancake_in_devcontainer() {
    [[ -n "${PANCAKE_DEVCONTAINER_DIR:-}" || -f /.dockerenv || -n "${REMOTE_CONTAINERS:-}" ]]
}

pancake_require_devcontainer() {
    if ! pancake_in_devcontainer; then
        echo "$1: run this inside the devcontainer (or its image build); it relies on the image's pinned tools and paths" >&2
        return 1
    fi
}

pancake_require_host() {
    if pancake_in_devcontainer; then
        echo "$1: run this on the host, outside the devcontainer" >&2
        return 1
    fi
}

pancake_devcontainer_source_pins() {
    local root="$1"
    # shellcheck disable=SC1091
    source "${root}/pins.sh"
    pancake_devcontainer_validate_pins
}

pancake_devcontainer_validate_pins() {
    if [[ "${ZIG_VERSION}" != "${ZLS_VERSION}" ]]; then
        echo "pins.sh: ZIG_VERSION (${ZIG_VERSION}) must equal ZLS_VERSION (${ZLS_VERSION})" >&2
        return 1
    fi
}

# Shared worktree-name grammar: lowercase letters and digits, starts with a
# letter, at most 12 characters. The .env reader and enter.sh both use this.
pancake_devcontainer_validate_worktree_name() {
    local value="$1"
    local what="${2:-PANCAKE_WORKTREE}"
    case "${value}" in
        [a-z]* ) ;;
        *)
            echo "devcontainer: ${what} must start with a lowercase letter" >&2
            return 1
            ;;
    esac
    case "${value}" in
        *[!a-z0-9]* )
            echo "devcontainer: ${what} may contain only lowercase letters and digits" >&2
            return 1
            ;;
    esac
    if [[ ${#value} -gt 12 ]]; then
        echo "devcontainer: ${what} must be at most 12 characters" >&2
        return 1
    fi
}

# A tmux session designator is a human-facing suffix, not container identity.
# Keep it target-safe and readable: tmux gives ':' and '.' special meaning,
# while a compact lowercase label remains unambiguous in session listings.
pancake_devcontainer_validate_session_designator() {
    local value="$1"
    case "${value}" in
        [a-z]* ) ;;
        *)
            echo "devcontainer: session designator must start with a lowercase letter" >&2
            return 1
            ;;
    esac
    case "${value}" in
        *[!a-z0-9-]* )
            echo "devcontainer: session designator may contain only lowercase letters, digits, and hyphens" >&2
            return 1
            ;;
    esac
    case "${value}" in
        *[a-z0-9] ) ;;
        *)
            echo "devcontainer: session designator must end with a lowercase letter or digit" >&2
            return 1
            ;;
    esac
    if [[ ${#value} -gt 24 ]]; then
        echo "devcontainer: session designator must be at most 24 characters" >&2
        return 1
    fi
}

# The default deliberately preserves the container-shaped session name used by
# existing launchers. An explicit designator creates another tmux session while
# retaining the worktree container as the shared execution identity.
pancake_devcontainer_tmux_session_name() {
    local worktree="$1" designator="${2:-}"
    pancake_devcontainer_validate_worktree_name "${worktree}" "worktree name" || return
    if [[ -n "${designator}" ]]; then
        pancake_devcontainer_validate_session_designator "${designator}" || return
        printf 'pancake-%s-%s\n' "${worktree}" "${designator}"
    else
        printf 'pancake-%s\n' "${worktree}"
    fi
}

pancake_devcontainer_validate_network_name() {
    local value="$1"
    local what="${2:-Docker network name}"
    case "${value}" in
        [A-Za-z0-9]* ) ;;
        *)
            echo "devcontainer: ${what} must start with a letter or digit" >&2
            return 1
            ;;
    esac
    case "${value}" in
        *[!A-Za-z0-9_.-]* )
            echo "devcontainer: ${what} may contain only letters, digits, dots, underscores, and hyphens" >&2
            return 1
            ;;
    esac
    if [[ ${#value} -gt 63 ]]; then
        echo "devcontainer: ${what} must be at most 63 characters" >&2
        return 1
    fi
}

pancake_devcontainer_default_egress_network() {
    printf 'pancake-%s-egress\n' "$1"
}

pancake_devcontainer_port_rows() {
    printf '%s\n' \
        PANCAKE_WEB_HOST_PORT:8000 \
        PANCAKE_CAPTP_HOST_PORT:9099 \
        PANCAKE_RELAY_HOST_PORT:9200 \
        PANCAKE_TRACE_HOST_PORT:9300
}

# Read one plain KEY=value assignment from the checkout-local Compose env file.
# The committed example owns this deliberately small form; the last declaration
# wins, matching Compose. The optional third argument is the absent/empty value.
pancake_devcontainer_env_value() {
    local root="$1" variable="$2" fallback="${3:-}" value
    value="$(sed -n "s/^${variable}=//p" "${root}/.env" 2>/dev/null | tail -1)"
    case "${value}" in
        \'*\')
            value="${value#\'}"
            value="${value%\'}"
            value="${value//\\\'/\'}"
            ;;
    esac
    if [[ -z "${value}" ]]; then
        value="${fallback}"
    fi
    printf '%s\n' "${value}"
}

# The variables Compose reads for a checkout's identity, named once. The guard
# below refuses an inherited value that disagrees with `.env`, and the host
# tests have to clear the same set before building checkouts of their own — two
# lists would drift, and the drift would show up as a test that passes on a host
# and fails in a devcontainer.
pancake_devcontainer_compose_variables() {
    cat <<'EOF'
PANCAKE_WORKTREE
PANCAKE_GIT_COMMON_DIR
PANCAKE_WEB_HOST_PORT
PANCAKE_CAPTP_HOST_PORT
PANCAKE_RELAY_HOST_PORT
PANCAKE_TRACE_HOST_PORT
EGRESS_NET
EOF
}

# Compose gives an exported host variable precedence over `.env`. Refuse a
# different inherited value so validation and execution cannot see two states.
pancake_devcontainer_validate_effective_env() {
    local root="$1" variable configured inherited
    while IFS= read -r variable; do
        configured="$(pancake_devcontainer_env_value "${root}" "${variable}")"
        if [[ -z "${configured}" ]]; then
            echo "devcontainer: ${variable} is missing from ${root}/.env" >&2
            echo "devcontainer: remove the incomplete file and run: bash .devcontainer/configure.sh" >&2
            return 1
        fi
        if printenv "${variable}" >/dev/null 2>&1; then
            inherited="$(printenv "${variable}")"
            if [[ "${inherited}" != "${configured}" ]]; then
                echo "devcontainer: exported ${variable}=${inherited}, but ${root}/.env sets ${configured}" >&2
                echo "devcontainer: unset ${variable}; .devcontainer/.env owns this checkout's Compose identity" >&2
                return 1
            fi
        fi
    done < <(pancake_devcontainer_compose_variables)
}

pancake_devcontainer_worktree_kind() {
    local checkout="$1" git_dir common_dir
    git_dir="$(git -C "${checkout}" rev-parse --path-format=absolute --git-dir)" || return 1
    common_dir="$(git -C "${checkout}" rev-parse --path-format=absolute --git-common-dir)" || return 1
    if [[ "${git_dir}" == "${common_dir}" ]]; then
        printf '%s\n' primary
    else
        printf '%s\n' linked
    fi
}

# Materialize the ignored Compose environment from Git-owned checkout facts.
# The primary checkout has the canonical ports. A linked checkout must choose
# an explicit offset because guessing an available host port would race Docker
# and silently couple independent worktrees.
pancake_devcontainer_configure_env() {
    local root="$1" offset="${2:-}" requested_egress="${3:-}"
    local checkout kind name common_dir escaped_common decimal_offset egress temp_file variable base

    if [[ -e "${root}/.env" ]]; then
        pancake_devcontainer_validate_checkout_env "${root}" >/dev/null || return
        echo "configure.sh: ${root}/.env already exists; leaving it unchanged" >&2
        return 0
    fi

    checkout="$(cd "${root}/.." && pwd -P)" || return
    kind="$(pancake_devcontainer_worktree_kind "${checkout}")" || return
    if [[ "${kind}" == primary ]]; then
        name=main
        [[ -n "${offset}" ]] || offset=0
    else
        name="${checkout##*/}"
        if [[ -z "${offset}" ]]; then
            echo "configure.sh: linked worktree ${name} needs an explicit host-port offset" >&2
            echo "configure.sh: run: bash .devcontainer/configure.sh --port-offset 10000" >&2
            return 1
        fi
    fi
    pancake_devcontainer_validate_worktree_name "${name}" "worktree directory" || return

    case "${offset}" in
        '' | *[!0-9]* )
            echo "configure.sh: --port-offset must be a non-negative decimal integer" >&2
            return 1
            ;;
    esac
    if [[ ${#offset} -gt 5 ]]; then
        echo "configure.sh: --port-offset makes a host port exceed 65535" >&2
        return 1
    fi
    decimal_offset=$((10#${offset}))
    while IFS=: read -r variable base; do
        if [[ $((base + decimal_offset)) -gt 65535 ]]; then
            echo "configure.sh: --port-offset makes ${variable} exceed 65535" >&2
            return 1
        fi
    done <<< "$(pancake_devcontainer_port_rows)"

    common_dir="$(git -C "${checkout}" rev-parse --path-format=absolute --git-common-dir)" || return
    case "${common_dir}" in
        *$'\n'* | *$'\r'*)
            echo "configure.sh: Git common directory cannot contain a newline" >&2
            return 1
            ;;
    esac
    escaped_common="${common_dir//\'/\\\'}"

    if [[ -n "${requested_egress}" ]]; then
        egress="${requested_egress}"
    else
        egress="$(pancake_devcontainer_default_egress_network "${name}")"
    fi
    pancake_devcontainer_validate_network_name "${egress}" EGRESS_NET || return

    temp_file="$(mktemp "${root}/.env.tmp.XXXXXX")" || return
    chmod 600 "${temp_file}"
    {
        printf 'PANCAKE_WORKTREE=%s\n' "${name}"
        printf "PANCAKE_GIT_COMMON_DIR='%s'\n" "${escaped_common}"
        while IFS=: read -r variable base; do
            printf '%s=%s\n' "${variable}" "$((base + decimal_offset))"
        done <<< "$(pancake_devcontainer_port_rows)"
        printf 'EGRESS_NET=%s\n' "${egress}"
    } > "${temp_file}"

    # A hard link is an atomic create-if-absent on the same filesystem. Two
    # editor windows may initialize together; one wins without overwriting the
    # checkout-local choice the other just made.
    if ln "${temp_file}" "${root}/.env" 2>/dev/null; then
        rm -f "${temp_file}"
        echo "configure.sh: wrote ${root}/.env for ${name}" >&2
        return 0
    fi
    rm -f "${temp_file}"
    if [[ -e "${root}/.env" ]]; then
        echo "configure.sh: ${root}/.env was created concurrently; leaving it unchanged" >&2
        return 0
    fi
    echo "configure.sh: could not create ${root}/.env" >&2
    return 1
}

# Read the checkout-local identity from Compose's ignored .env file.
pancake_devcontainer_worktree_name() {
    local root="$1" value
    value="$(pancake_devcontainer_env_value "${root}" PANCAKE_WORKTREE)"
    if [[ -z "${value}" ]]; then
        echo "devcontainer: PANCAKE_WORKTREE is missing from ${root}/.env" >&2
        echo "devcontainer: remove the incomplete file and run: bash .devcontainer/configure.sh" >&2
        return 1
    fi
    pancake_devcontainer_validate_worktree_name "${value}" || return
    printf '%s\n' "${value}"
}

pancake_devcontainer_primary_checkout() {
    local checkout="$1" line listing
    listing="$(git -C "${checkout}" worktree list --porcelain)" || return 1
    while IFS= read -r line; do
        case "${line}" in
            worktree\ *)
                printf '%s\n' "${line#worktree }"
                return 0
                ;;
        esac
    done <<< "${listing}"
    echo "devcontainer: Git did not report a primary checkout for ${checkout}" >&2
    return 1
}

# `main` is the primary checkout that owns the common Git directory. Any other
# name is a linked worktree whose directory basename is that name. Git's
# registered worktree list is the only authority on where it lives.
pancake_devcontainer_checkout_for_worktree() {
    local primary="$1" name="$2" path listed="" line listing
    if [[ "${name}" == main ]]; then
        printf '%s\n' "${primary}"
        return 0
    fi
    listing="$(git -C "${primary}" worktree list --porcelain)" || return 1
    while IFS= read -r line; do
        case "${line}" in
            worktree\ *)
                path="${line#worktree }"
                [[ "${path}" == "${primary}" ]] && continue
                if [[ "${path##*/}" == "${name}" ]]; then
                    if [[ -n "${listed}" ]]; then
                        echo "devcontainer: multiple worktrees are named ${name}" >&2
                        return 1
                    fi
                    listed="${path}"
                fi
                ;;
        esac
    done <<< "${listing}"
    if [[ -n "${listed}" ]]; then
        printf '%s\n' "${listed}"
        return 0
    fi
    echo "devcontainer: Git has no linked worktree named ${name}" >&2
    return 1
}

# Dev Containers labels the running container with the exact host checkout.
# That label, not a presentation name, is the authority for docker exec: it
# binds execution to this exact checkout and cannot select another clone.
pancake_devcontainer_running_container() {
    local checkout="$1" ids count
    ids="$(docker ps --filter "label=devcontainer.local_folder=${checkout}" --format '{{.ID}}')" || return 1
    count="$(printf '%s\n' "${ids}" | sed '/^$/d' | wc -l | tr -d ' ')"
    case "${count}" in
        1) printf '%s\n' "${ids}" ;;
        0)
            echo "devcontainer: no running container is labeled for ${checkout}" >&2
            return 1
            ;;
        *)
            echo "devcontainer: multiple running containers are labeled for ${checkout}" >&2
            return 1
            ;;
    esac
}

pancake_devcontainer_ensure_network() {
    local name="$1" ownership="$2"
    if docker network inspect "${name}" >/dev/null 2>&1; then
        return 0
    fi
    if [[ "${ownership}" != managed ]]; then
        echo "devcontainer: Docker network '${name}' does not exist" >&2
        echo "devcontainer: create that external network, or remove .devcontainer/.env and run configure.sh for an isolated default" >&2
        return 1
    fi
    docker network create "${name}" >/dev/null 2>&1 ||
        docker network inspect "${name}" >/dev/null
}

# The ignored value is useful only if the worktree and container identities
# agree. The primary checkout may live in a repository directory named
# `pancake`; linked worktrees use their designator as the directory basename.
# Branch names are intentionally independent.
pancake_devcontainer_validate_worktree() {
    local root="$1" name="$2" checkout kind
    checkout="$(basename "$(cd "${root}/.." && pwd -P)")"
    kind="$(pancake_devcontainer_worktree_kind "${root}/..")" || return
    if [[ "${kind}" == primary ]]; then
        if [[ "${name}" != main ]]; then
            echo "devcontainer: the primary checkout must use PANCAKE_WORKTREE=main, not ${name}" >&2
            return 1
        fi
    elif [[ "${name}" == main ]]; then
        echo "devcontainer: a linked worktree may not use PANCAKE_WORKTREE=main" >&2
        return 1
    elif [[ "${checkout}" != "${name}" ]]; then
        echo "devcontainer: PANCAKE_WORKTREE=${name}, but the worktree directory is ${checkout}" >&2
        echo "devcontainer: use the same short name for the worktree and container" >&2
        return 1
    fi
}

# Linked worktrees store their administrative state in the primary checkout's
# common Git directory. Their .git file may contain an absolute host path, so
# Compose must mount that directory at the same path inside the container.
pancake_devcontainer_validate_git_common_dir() {
    local root="$1" configured expected
    configured="$(pancake_devcontainer_env_value "${root}" PANCAKE_GIT_COMMON_DIR)"
    if [[ -z "${configured}" ]]; then
        echo "devcontainer: set PANCAKE_GIT_COMMON_DIR in .devcontainer/.env" >&2
        echo "devcontainer: obtain it with: git rev-parse --path-format=absolute --git-common-dir" >&2
        return 1
    fi
    expected="$(git -C "${root}/.." rev-parse --path-format=absolute --git-common-dir)"
    if [[ "${configured}" != "${expected}" ]]; then
        echo "devcontainer: PANCAKE_GIT_COMMON_DIR=${configured}" >&2
        echo "devcontainer: expected ${expected}" >&2
        return 1
    fi
    if [[ ! -d "${configured}" ]]; then
        echo "devcontainer: PANCAKE_GIT_COMMON_DIR is not a directory: ${configured}" >&2
        return 1
    fi
}

# Refuse malformed or duplicate host bindings before Compose reaches Docker.
# Port availability is still Docker's authority because checking then binding
# separately would introduce a race.
pancake_devcontainer_validate_host_ports() {
    local root="$1" variable base value decimal seen="" prior
    while IFS=: read -r variable base; do
        value="$(pancake_devcontainer_env_value "${root}" "${variable}")"
        case "${value}" in
            '' | *[!0-9]* )
                echo "devcontainer: ${variable} must be a decimal port" >&2
                return 1
                ;;
        esac
        if [[ ${#value} -gt 5 ]]; then
            echo "devcontainer: ${variable} must be between 1 and 65535" >&2
            return 1
        fi
        decimal=$((10#${value}))
        if [[ "${decimal}" -lt 1 || "${decimal}" -gt 65535 ]]; then
            echo "devcontainer: ${variable} must be between 1 and 65535" >&2
            return 1
        fi
        for prior in ${seen}; do
            if [[ "${prior}" == "${decimal}" ]]; then
                echo "devcontainer: host port ${decimal} is assigned more than once in .devcontainer/.env" >&2
                return 1
            fi
        done
        seen="${seen} ${decimal}"
    done <<< "$(pancake_devcontainer_port_rows)"
}

# One complete acceptance path for the checkout-local Compose environment.
# Callers receive the validated worktree name and do not restate the sequence.
pancake_devcontainer_validate_checkout_env() {
    local root="$1" worktree_name egress
    pancake_devcontainer_validate_effective_env "${root}" || return
    worktree_name="$(pancake_devcontainer_worktree_name "${root}")" || return
    pancake_devcontainer_validate_worktree "${root}" "${worktree_name}" || return
    pancake_devcontainer_validate_git_common_dir "${root}" || return
    pancake_devcontainer_validate_host_ports "${root}" || return
    egress="$(pancake_devcontainer_env_value "${root}" EGRESS_NET)"
    pancake_devcontainer_validate_network_name "${egress}" EGRESS_NET || return
    printf '%s\n' "${worktree_name}"
}

# Call after sourcing lib.sh. Optional second argument: checksums
pancake_devcontainer_init() {
    local root="$1"
    local with_checksums="${2:-}"
    if [[ "${with_checksums}" == checksums ]]; then
        # shellcheck disable=SC1091
        source "${root}/checksums.sh"
    fi
    pancake_devcontainer_source_pins "${root}"
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    if [[ -z "${expected}" ]]; then
        echo "missing SHA-256 for ${file}" >&2
        return 1
    fi
    # macOS runners carry shasum, not sha256sum.
    if command -v sha256sum >/dev/null 2>&1; then
        echo "${expected}  ${file}" | sha256sum --check -
    else
        echo "${expected}  ${file}" | shasum -a 256 --check -
    fi
}

# Download a URL to a destination and verify it against a pinned SHA-256.
# Every remote byte an installer consumes comes through here.
fetch_verified() {
    local url="$1"
    local dest="$2"
    local sha256="$3"
    echo "downloading ${url}" >&2
    curl --fail --location --silent --show-error --output "${dest}" "${url}"
    verify_sha256 "${dest}" "${sha256}"
}

# Select a per-architecture value: x86_64 value first, then aarch64. The
# mapping that calls this is the authority on which architectures its tool
# supports, so an unsupported machine fails here, at the point of use.
pick_by_arch() {
    local label="$1"
    local x86_64_value="$2"
    local aarch64_value="$3"
    case "$(uname -m)" in
        x86_64) echo "${x86_64_value}" ;;
        aarch64) echo "${aarch64_value}" ;;
        *)
            echo "${label}: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}

# For installers with no per-architecture mapping of their own.
require_arch() {
    case "$(uname -m)" in
        x86_64 | aarch64) return 0 ;;
        *)
            echo "${1}: unsupported architecture: $(uname -m)" >&2
            return 1
            ;;
    esac
}
