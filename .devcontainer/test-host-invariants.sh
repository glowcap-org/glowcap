#!/usr/bin/env bash
# Self-contained tests for host-side configuration, identity, and lookup.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# launcher-lib.sh sources lib.sh, so this covers both surfaces under test.
# shellcheck source=launcher-lib.sh
source "${dir}/launcher-lib.sh"

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

expect_launcher_error() {
    local launcher="$1" expected="$2" output
    shift 2
    if output="$(bash "${dir}/${launcher}" "$@" 2>&1)"; then
        echo "test-host-invariants: ${launcher} unexpectedly accepted: $*" >&2
        exit 1
    fi
    if [[ "${output}" != *"${expected}"* ]]; then
        echo "test-host-invariants: ${launcher} did not report '${expected}' for: $*" >&2
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

expect_launcher_error enter.sh "mutually exclusive" --rebuild --no-cache
expect_launcher_error enter.sh "--session requires a designator" --session
expect_launcher_error enter.sh "--session requires a designator" --session=
expect_launcher_error enter.sh "specify --session at most once" --session review --session other
expect_launcher_error enter.sh "must start with a lowercase letter" --session Review
expect_launcher_error enter.sh "must start with a lowercase letter" --session=Review
expect_launcher_error enter-grid.sh "mutually exclusive" --rebuild --no-cache
expect_launcher_error enter-grid.sh "--session requires a designator" --session
expect_launcher_error enter-grid.sh "specify --session at most once" --session review --session other
expect_launcher_error enter-grid.sh "must start with a lowercase letter" --session Review
expect_launcher_error enter-grid.sh "listed more than once" main tree1 main
expect_launcher_error enter-grid.sh "may contain only lowercase letters and digits" "tree_1"
expect_launcher_error enter.sh "--cc and --no-cc are mutually exclusive" --cc --no-cc
expect_launcher_error enter-grid.sh "--cc and --no-cc are mutually exclusive" --no-cc --cc

# Control-mode detection recognizes iTerm2 locally and over ssh, and no one
# else.
if TERM_PROGRAM= LC_TERMINAL= pancake_devcontainer_client_is_iterm2; then
    echo "test-host-invariants: a non-iTerm2 client was detected as iTerm2" >&2
    exit 1
fi
TERM_PROGRAM=iTerm.app pancake_devcontainer_client_is_iterm2
TERM_PROGRAM= LC_TERMINAL=iTerm2 pancake_devcontainer_client_is_iterm2
grid_help_output="$(bash "${dir}/enter-grid.sh" --help)"
[[ "${grid_help_output}" == *"columns: every registered worktree"* ]]
[[ "${grid_help_output}" == *"tmux: pancake-grid-review"* ]]

# pane-rc.sh sources the worktree's panes.sh in an initialized interactive
# shell: top-level lines run in every pane, and the pane function matching
# this pane's row runs as its startup command.
grid="${scratch}/grid"
mkdir -p "${grid}/.devcontainer"
cp "${dir}/pane-rc.sh" "${grid}/.devcontainer/pane-rc.sh"
cat > "${grid}/.devcontainer/panes.sh" <<'EOF'
echo shared >> shared.count
pane1() { echo top > pane.out; }
pane3() { echo bottom > pane.out; }
EOF
printf 'pane1() { echo review > pane.out; }\n' \
    > "${grid}/.devcontainer/panes-review.sh"
run_grid_pane() {
    rm -f "${grid}/pane.out"
    (cd "${grid}" && printf 'exit\n' |
        HOME="${grid}" PANCAKE_GRID_ROW="$1" PANCAKE_GRID_PANES="$2" \
            bash --rcfile .devcontainer/pane-rc.sh -i >/dev/null 2>&1)
    cat "${grid}/pane.out" 2>/dev/null || true
}
[[ "$(run_grid_pane 1 panes.sh)" == top ]]
if [[ -n "$(run_grid_pane 2 panes.sh)" ]]; then
    echo "test-host-invariants: an undeclared pane function ran a command" >&2
    exit 1
fi
[[ "$(run_grid_pane 3 panes.sh)" == bottom ]]
[[ "$(run_grid_pane 1 panes-review.sh)" == review ]]
[[ "$(wc -l < "${grid}/shared.count" | tr -d ' ')" -eq 3 ]]

# The same file also decides its column's row count, by textual scan.
[[ "$(pancake_devcontainer_grid_rows "${grid}/.devcontainer/panes.sh")" == 3 ]]
[[ "$(pancake_devcontainer_grid_rows "${grid}/.devcontainer/panes-review.sh")" == 1 ]]
[[ "$(pancake_devcontainer_grid_rows "${grid}/.devcontainer/absent.sh")" == 0 ]]
printf 'function pane5() { :; }\n' > "${grid}/.devcontainer/panes-tall.sh"
[[ "$(pancake_devcontainer_grid_rows "${grid}/.devcontainer/panes-tall.sh")" == 5 ]]

rm "${grid}/.devcontainer/panes.sh"
if [[ -n "$(run_grid_pane 1 panes.sh)" ]]; then
    echo "test-host-invariants: a missing panes.sh ran a command" >&2
    exit 1
fi
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
[[ "$(pancake_devcontainer_env_value "${linked}/.devcontainer" PANCAKE_ROOMS_WEB_HOST_PORT)" == 18000 ]]
[[ "$(pancake_devcontainer_env_value "${linked}/.devcontainer" PANCAKE_DOCS_HOST_PORT)" == 11990 ]]
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
[[ "$(pancake_devcontainer_registered_worktrees "${primary}" | tr '\n' ':')" == "main:tree1:" ]]
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
PANCAKE_ROOMS_WEB_HOST_PORT=08000
PANCAKE_ROOMS_CAPTP_HOST_PORT=8000
EOF
if pancake_devcontainer_validate_host_ports "${primary}/.devcontainer" >/dev/null 2>&1; then
    echo "test-host-invariants: equivalent decimal ports were not treated as duplicates" >&2
    exit 1
fi
