# shellcheck shell=bash
# The ignored .env each checkout carries: writing it, reading it, and
# refusing one that does not describe this checkout.
#
# That file is the checkout's identity as Compose sees it, so a value read
# here is the same value the container is built with. Nothing in this module
# guesses a missing value into place: an incomplete file is refused, and
# bin/configure.sh is the command that writes a complete one.

# Encode and decode the small dotenv form this module writes for values that
# must not undergo Compose interpolation. Compose treats `\'` inside a
# single-quoted value as a literal quote; keep that one escape form here so the
# writer and reader cannot drift.
glowcap_devcontainer_env_quote_value() {
    local value="$1" quote="'" escaped="\\'"
    printf "'%s'\n" "${value//${quote}/${escaped}}"
}

glowcap_devcontainer_env_unquote_value() {
    local value="$1"
    case "${value}" in
        \'*\')
            value="${value#\'}"
            value="${value%\'}"
            value="$(printf '%s\n' "${value}" | sed "s/\\\\'/'/g")"
            ;;
    esac
    printf '%s\n' "${value}"
}

# Read one plain KEY=value assignment from the checkout-local Compose env file.
# The committed example owns this deliberately small form; the last declaration
# wins, matching Compose. The optional third argument is the absent/empty value.
glowcap_devcontainer_env_value() {
    local root="$1" variable="$2" fallback="${3:-}" value
    value="$(sed -n "s/^${variable}=//p" "${root}/.env" 2>/dev/null | tail -1)"
    value="$(glowcap_devcontainer_env_unquote_value "${value}")"
    if [[ -z "${value}" ]]; then
        value="${fallback}"
    fi
    printf '%s\n' "${value}"
}

# Add the host ports the table has gained since this .env was written, at the
# offset the file already uses.
#
# The table is the authority on which ports a checkout publishes, so a row
# added to it makes every existing .env incomplete at once. Refusing them is
# right; the only remedy on offer used to be deleting a file that holds the
# operator's chosen ports and network, which is a poor trade for one missing
# line. This adds what is missing and touches nothing else.
#
# The offset is read from the rows the file already carries, and every one of
# them has to agree: a file whose ports came from two different offsets is not
# something to guess about, so it is reported and left alone. A file carrying
# no ports at all is not an outgrown .env, and ordinary validation owns it.
glowcap_devcontainer_complete_env() {
    local root="$1" variable base value offset seen_offset="" missing="" missing_count=0
    local checkout
    [[ -e "${root}/.env" ]] || return 0

    # Older files predate the checkout's same-path bind. That bind gives
    # submodule repositories one absolute worktree path that exists on both
    # the host and in the container, so this Git-owned fact is safe to add
    # without disturbing the operator-owned ports or egress network.
    if [[ -z "$(glowcap_devcontainer_env_value "${root}" GLOWCAP_CHECKOUT_DIR)" ]]; then
        checkout="$(cd "${root}/.." && pwd -P)" || return
        printf 'GLOWCAP_CHECKOUT_DIR=%s\n' \
            "$(glowcap_devcontainer_env_quote_value "${checkout}")" >> "${root}/.env"
        echo "devcontainer: added GLOWCAP_CHECKOUT_DIR=${checkout} to ${root}/.env" >&2
    fi

    while IFS=: read -r variable base; do
        value="$(glowcap_devcontainer_env_value "${root}" "${variable}")"
        if [[ -z "${value}" ]]; then
            missing="${missing}${variable}:${base} "
            missing_count=$((missing_count + 1))
            continue
        fi
        case "${value}" in
            '' | *[!0-9]*) return 0 ;;
        esac
        offset=$((10#${value} - base))
        if [[ -z "${seen_offset}" ]]; then
            seen_offset="${offset}"
        elif [[ "${seen_offset}" != "${offset}" ]]; then
            echo "devcontainer: ${root}/.env host ports disagree about their offset (${seen_offset} and ${offset})" >&2
            echo "devcontainer: set them by hand, or remove the file and run: bash .devcontainer/bin/configure.sh --port-offset <n>" >&2
            return 1
        fi
    done <<< "$(glowcap_devcontainer_port_rows)"
    [[ "${missing_count}" -gt 0 ]] || return 0
    if [[ -z "${seen_offset}" ]]; then
        return 0
    fi
    for variable in ${missing}; do
        base="${variable#*:}"
        variable="${variable%%:*}"
        if [[ $((base + seen_offset)) -gt 65535 ]]; then
            echo "devcontainer: ${variable} at offset ${seen_offset} would exceed 65535" >&2
            return 1
        fi
        printf '%s=%s\n' "${variable}" "$((base + seen_offset))" >> "${root}/.env"
        echo "devcontainer: added ${variable}=$((base + seen_offset)) to ${root}/.env" >&2
    done
}

# Compose gives an exported host variable precedence over `.env`. Refuse a
# different inherited value so validation and execution cannot see two states.
glowcap_devcontainer_validate_effective_env() {
    local root="$1" variable configured inherited
    while IFS= read -r variable; do
        configured="$(glowcap_devcontainer_env_value "${root}" "${variable}")"
        if [[ -z "${configured}" ]]; then
            echo "devcontainer: ${variable} is missing from ${root}/.env" >&2
            echo "devcontainer: run: bash .devcontainer/bin/configure.sh, which adds what the table has gained" >&2
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
    done < <(glowcap_devcontainer_compose_variables)
}

# Materialize the ignored Compose environment from Git-owned checkout facts.
# The primary checkout has the canonical ports. A linked checkout must choose
# an explicit offset because guessing an available host port would race Docker
# and silently couple independent worktrees.
glowcap_devcontainer_configure_env() {
    local root="$1" offset="${2:-}" requested_egress="${3:-}"
    local checkout kind name common_dir decimal_offset egress temp_file variable base

    if [[ -e "${root}/.env" ]]; then
        glowcap_devcontainer_complete_env "${root}" || return
        glowcap_devcontainer_validate_checkout_env "${root}" >/dev/null || return
        echo "configure.sh: ${root}/.env is complete; its values are left as they are" >&2
        return 0
    fi

    checkout="$(cd "${root}/.." && pwd -P)" || return
    kind="$(glowcap_devcontainer_worktree_kind "${checkout}")" || return
    if [[ "${kind}" == primary ]]; then
        name=main
        [[ -n "${offset}" ]] || offset=0
    else
        name="${checkout##*/}"
        if [[ -z "${offset}" ]]; then
            echo "configure.sh: linked worktree ${name} needs an explicit host-port offset" >&2
            echo "configure.sh: run: bash .devcontainer/bin/configure.sh --port-offset 10000" >&2
            return 1
        fi
    fi
    glowcap_devcontainer_validate_worktree_name "${name}" "worktree directory" || return

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
    done <<< "$(glowcap_devcontainer_port_rows)"

    common_dir="$(git -C "${checkout}" rev-parse --path-format=absolute --git-common-dir)" || return
    case "${common_dir}" in
        *$'\n'* | *$'\r'*)
            echo "configure.sh: Git common directory cannot contain a newline" >&2
            return 1
            ;;
    esac
    if [[ -n "${requested_egress}" ]]; then
        egress="${requested_egress}"
    else
        egress="$(glowcap_devcontainer_default_egress_network "${name}")"
    fi
    glowcap_devcontainer_validate_network_name "${egress}" EGRESS_NET || return

    temp_file="$(mktemp "${root}/.env.tmp.XXXXXX")" || return
    chmod 600 "${temp_file}"
    {
        printf 'GLOWCAP_WORKTREE=%s\n' "${name}"
        printf 'GLOWCAP_CHECKOUT_DIR=%s\n' "$(glowcap_devcontainer_env_quote_value "${checkout}")"
        printf 'GLOWCAP_GIT_COMMON_DIR=%s\n' "$(glowcap_devcontainer_env_quote_value "${common_dir}")"
        while IFS=: read -r variable base; do
            printf '%s=%s\n' "${variable}" "$((base + decimal_offset))"
        done <<< "$(glowcap_devcontainer_port_rows)"
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

# Refuse malformed or duplicate host bindings before Compose reaches Docker.
# Port availability is still Docker's authority because checking then binding
# separately would introduce a race.
glowcap_devcontainer_validate_host_ports() {
    local root="$1" variable base value decimal seen="" prior
    while IFS=: read -r variable base; do
        value="$(glowcap_devcontainer_env_value "${root}" "${variable}")"
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
    done <<< "$(glowcap_devcontainer_port_rows)"
}

# One complete acceptance path for the checkout-local Compose environment.
# Callers receive the validated worktree name and do not restate the sequence.
glowcap_devcontainer_validate_checkout_env() {
    local root="$1" worktree_name egress
    glowcap_devcontainer_validate_effective_env "${root}" || return
    worktree_name="$(glowcap_devcontainer_worktree_name "${root}")" || return
    glowcap_devcontainer_validate_worktree "${root}" "${worktree_name}" || return
    glowcap_devcontainer_validate_checkout_dir "${root}" || return
    glowcap_devcontainer_validate_git_common_dir "${root}" || return
    glowcap_devcontainer_validate_host_ports "${root}" || return
    egress="$(glowcap_devcontainer_env_value "${root}" EGRESS_NET)"
    glowcap_devcontainer_validate_network_name "${egress}" EGRESS_NET || return
    printf '%s\n' "${worktree_name}"
}
