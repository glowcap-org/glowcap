#!/usr/bin/env bash
# Self-contained tests for host-side configuration, identity, and lookup.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"

# These tests build checkouts of their own and configure them. Run inside a
# devcontainer, the surrounding checkout's identity is exported into this
# process, and `validate_effective_env` is right to refuse a fixture whose
# `.env` says something else — so the ambient identity is cleared here rather
# than the guard being weakened. The list is the one the guard reads.
while IFS= read -r pancake_compose_variable; do
    unset "${pancake_compose_variable}"
done < <(pancake_devcontainer_compose_variables)
unset pancake_compose_variable

scratch="$(mktemp -d)"
cleanup() {
    rm -rf -- "${scratch}"
}
trap cleanup EXIT

expect_enter_error() {
    local expected="$1" output
    shift
    if output="$(bash "${dir}/enter.sh" "$@" 2>&1)"; then
        echo "test-host-invariants: enter.sh unexpectedly accepted: $*" >&2
        exit 1
    fi
    if [[ "${output}" != *"${expected}"* ]]; then
        echo "test-host-invariants: enter.sh did not report '${expected}' for: $*" >&2
        exit 1
    fi
}

mkdir "${scratch}/host"
ln -s "${dir}/enter.sh" "${scratch}/host/pancake"
help_output="$(cd / && "${scratch}/host/pancake" --help)"
[[ "${help_output}" == *"bash .devcontainer/enter.sh tree1"* ]]
[[ "${help_output}" == *"--session review"* ]]

[[ "$(pancake_devcontainer_tmux_session_name main)" == pancake-main ]]
[[ "$(pancake_devcontainer_tmux_session_name main review)" == pancake-main-review ]]
[[ "$(pancake_devcontainer_tmux_session_name tree1 investigation-2)" == pancake-tree1-investigation-2 ]]
pancake_devcontainer_validate_session_designator review
pancake_devcontainer_validate_session_designator investigation-2
pancake_devcontainer_validate_session_designator abcdefghijklmnopqrstuvwx
for invalid_session in Review review_one review:one -review review- 123review; do
    if pancake_devcontainer_validate_session_designator "${invalid_session}" >/dev/null 2>&1; then
        echo "test-host-invariants: accepted invalid session designator: ${invalid_session}" >&2
        exit 1
    fi
done
if pancake_devcontainer_validate_session_designator abcdefghijklmnopqrstuvwxy >/dev/null 2>&1; then
    echo "test-host-invariants: accepted an overlong session designator" >&2
    exit 1
fi

mkdir "${scratch}/bin"
# The single quotes are the source text of the fake command, not this shell's
# interpolation context.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == ps ]]; then printf "abc123\\n"; exit 0; fi' \
    'printf "%s\\n" "$*"' > "${scratch}/bin/docker"
chmod 755 "${scratch}/bin/docker"
ln -s "${dir}/../.agents/skills/work/bin/pancake-dev" "${scratch}/host/pancake-dev"
dev_exec="$(cd / && PATH="${scratch}/bin:${PATH}" PANCAKE_DEV_CONTAINER=test-container "${scratch}/host/pancake-dev" /bin/true)"
[[ "${dev_exec}" == *"--workdir /workspaces/pancake abc123 /bin/true"* ]]

expect_enter_error "mutually exclusive" --rebuild --no-cache
expect_enter_error "--session requires a designator" --session
expect_enter_error "--session requires a designator" --session=
expect_enter_error "specify --session at most once" --session review --session other
expect_enter_error "must start with a lowercase letter" --session Review
expect_enter_error "must start with a lowercase letter" --session=Review
if bash "${dir}/up.sh" --rebuild unexpected >/dev/null 2>&1; then
    echo "test-host-invariants: up.sh ignored an extra argument" >&2
    exit 1
fi

primary="${scratch}/repo #cash\$ O'Neil"
linked="${scratch}/tree1"
git init -q "${primary}"
git -C "${primary}" config user.email test@pancake.invalid
git -C "${primary}" config user.name "pancake test"
touch "${primary}/seed"
git -C "${primary}" add seed
git -C "${primary}" commit -qm seed
git -C "${primary}" worktree add -q -b test-tree1 "${linked}"
mkdir -p "${primary}/.devcontainer" "${linked}/.devcontainer"

printf 'PANCAKE_WORKTREE=main\n' > "${primary}/.devcontainer/.env"
if pancake_devcontainer_configure_env "${primary}/.devcontainer" >/dev/null 2>&1; then
    echo "test-host-invariants: configure accepted an incomplete existing environment" >&2
    exit 1
fi
rm "${primary}/.devcontainer/.env"
pancake_devcontainer_configure_env "${primary}/.devcontainer" >/dev/null 2>&1
[[ "$(pancake_devcontainer_env_value "${primary}/.devcontainer" PANCAKE_WORKTREE)" == main ]]
[[ "$(pancake_devcontainer_env_value "${primary}/.devcontainer" EGRESS_NET)" == pancake-main-egress ]]
[[ "$(pancake_devcontainer_env_value "${primary}/.devcontainer" PANCAKE_GIT_COMMON_DIR)" == "${primary}/.git" ]]
pancake_devcontainer_configure_env "${primary}/.devcontainer" 10000 other-network >/dev/null 2>&1
[[ "$(pancake_devcontainer_env_value "${primary}/.devcontainer" EGRESS_NET)" == pancake-main-egress ]]
[[ "$(pancake_devcontainer_worktree_name "${primary}/.devcontainer")" == main ]]
pancake_devcontainer_validate_worktree "${primary}/.devcontainer" main

if pancake_devcontainer_worktree_name "${linked}/.devcontainer" >/dev/null 2>&1; then
    echo "test-host-invariants: an incomplete worktree environment acquired an implicit identity" >&2
    exit 1
fi

if pancake_devcontainer_configure_env "${linked}/.devcontainer" >/dev/null 2>&1; then
    echo "test-host-invariants: linked worktree guessed its host ports" >&2
    exit 1
fi
pancake_devcontainer_configure_env "${linked}/.devcontainer" 10000 >/dev/null 2>&1
[[ "$(pancake_devcontainer_worktree_name "${linked}/.devcontainer")" == tree1 ]]
[[ "$(pancake_devcontainer_env_value "${linked}/.devcontainer" PANCAKE_WEB_HOST_PORT)" == 18000 ]]
[[ "$(pancake_devcontainer_env_value "${linked}/.devcontainer" EGRESS_NET)" == pancake-tree1-egress ]]
pancake_devcontainer_validate_worktree "${linked}/.devcontainer" tree1
[[ "$(pancake_devcontainer_primary_checkout "${linked}")" == "${primary}" ]]

if pancake_devcontainer_validate_worktree "${linked}/.devcontainer" main >/dev/null 2>&1; then
    echo "test-host-invariants: linked worktree accepted the main identity" >&2
    exit 1
fi
if pancake_devcontainer_validate_worktree "${primary}/.devcontainer" tree1 >/dev/null 2>&1; then
    echo "test-host-invariants: primary checkout accepted a linked identity" >&2
    exit 1
fi

[[ "$(pancake_devcontainer_checkout_for_worktree "${primary}" tree1)" == "${linked}" ]]
if pancake_devcontainer_checkout_for_worktree "${primary}" missing >/dev/null 2>&1; then
    echo "test-host-invariants: lookup invented an unregistered worktree" >&2
    exit 1
fi

fake_docker_output=abc123
docker() {
    printf '%s\n' "${fake_docker_output}"
}
[[ "$(pancake_devcontainer_running_container "${primary}")" == abc123 ]]
fake_docker_output=$'abc123\ndef456'
if pancake_devcontainer_running_container "${primary}" >/dev/null 2>&1; then
    echo "test-host-invariants: ambiguous container labels selected one container" >&2
    exit 1
fi
unset -f docker

network_exists=false
network_created=""
docker() {
    if [[ "$1" == network && "$2" == inspect ]]; then
        [[ "${network_exists}" == true ]]
        return
    fi
    if [[ "$1" == network && "$2" == create ]]; then
        network_created="$3"
        network_exists=true
        return
    fi
    return 1
}
pancake_devcontainer_ensure_network pancake-main-egress managed
[[ "${network_created}" == pancake-main-egress ]]
network_exists=false
if pancake_devcontainer_ensure_network missing-external external >/dev/null 2>&1; then
    echo "test-host-invariants: startup created an operator-owned external network" >&2
    exit 1
fi
unset -f docker

if PANCAKE_WORKTREE=other pancake_devcontainer_validate_effective_env "${primary}/.devcontainer" >/dev/null 2>&1; then
    echo "test-host-invariants: inherited Compose identity bypassed .env" >&2
    exit 1
fi
PANCAKE_WORKTREE=main pancake_devcontainer_validate_effective_env "${primary}/.devcontainer"

cat >> "${primary}/.devcontainer/.env" <<'EOF'
PANCAKE_WEB_HOST_PORT=08000
PANCAKE_CAPTP_HOST_PORT=8000
EOF
if pancake_devcontainer_validate_host_ports "${primary}/.devcontainer" >/dev/null 2>&1; then
    echo "test-host-invariants: equivalent decimal ports were not treated as duplicates" >&2
    exit 1
fi
