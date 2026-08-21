#!/usr/bin/env bash
# Self-contained tests for host-side configuration, identity, and lookup.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# lib/launcher.sh sources lib/mod.sh, so this covers both surfaces under test.
# shellcheck source=../lib/launcher.sh
source "${dir}/lib/launcher.sh"

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
    if output="$(bash "${dir}/bin/${launcher}" "$@" 2>&1)"; then
        echo "test/host-invariants: ${launcher} unexpectedly accepted: $*" >&2
        exit 1
    fi
    if [[ "${output}" != *"${expected}"* ]]; then
        echo "test/host-invariants: ${launcher} did not report '${expected}' for: $*" >&2
        exit 1
    fi
}

mkdir "${scratch}/host"
ln -s "${dir}/bin/enter.sh" "${scratch}/host/pancake"
help_output="$(cd / && "${scratch}/host/pancake" --help)"
[[ "${help_output}" == *"bash .devcontainer/bin/enter.sh tree1"* ]]
[[ "${help_output}" == *"--session review"* ]]

[[ "$(pancake_devcontainer_tmux_session_name main)" == pancake-main ]]
[[ "$(pancake_devcontainer_tmux_session_name main review)" == pancake-main-review ]]
[[ "$(pancake_devcontainer_tmux_session_name tree1 investigation-2)" == pancake-tree1-investigation-2 ]]
pancake_devcontainer_validate_session_designator review
pancake_devcontainer_validate_session_designator investigation-2
pancake_devcontainer_validate_session_designator abcdefghijklmnopqrstuvwx
for invalid_session in Review review_one review:one -review review- 123review; do
    if pancake_devcontainer_validate_session_designator "${invalid_session}" >/dev/null 2>&1; then
        echo "test/host-invariants: accepted invalid session designator: ${invalid_session}" >&2
        exit 1
    fi
done
if pancake_devcontainer_validate_session_designator abcdefghijklmnopqrstuvwxy >/dev/null 2>&1; then
    echo "test/host-invariants: accepted an overlong session designator" >&2
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
if TERM_PROGRAM='' LC_TERMINAL='' pancake_devcontainer_client_is_iterm2; then
    echo "test/host-invariants: a non-iTerm2 client was detected as iTerm2" >&2
    exit 1
fi
TERM_PROGRAM=iTerm.app pancake_devcontainer_client_is_iterm2
TERM_PROGRAM='' LC_TERMINAL=iTerm2 pancake_devcontainer_client_is_iterm2
grid_help_output="$(bash "${dir}/bin/enter-grid.sh" --help)"
[[ "${grid_help_output}" == *"columns: every registered worktree"* ]]
[[ "${grid_help_output}" == *"tmux: pancake-grid-review"* ]]

# The container half of the pane runtime sources the worktree's panes.sh in
# an initialized interactive shell: top-level lines run in every pane, and the
# pane function matching this pane's row runs as its startup command. It is a
# zsh rc, and zsh finds it through ZDOTDIR, so the fixture is a directory of
# that shape. The host half needs docker and a running container, so what is
# checked here is the half a shell alone can answer for.
grid="${scratch}/grid"
mkdir -p "${grid}/.devcontainer/pane/container"
cp "${dir}/pane/container/.zshrc" "${grid}/.devcontainer/pane/container/.zshrc"
cat > "${grid}/.devcontainer/pane/panes.sh" <<'EOF'
echo shared >> shared.count
pane1() { echo top > pane.out; }
pane3() { echo bottom > pane.out; }
EOF
printf 'pane1() { echo review > pane.out; }\n' \
    > "${grid}/.devcontainer/pane/panes-review.sh"
run_pane_shell() {
    (cd "${grid}" && printf '%s\n' "$1" |
        HOME="${grid}" ZDOTDIR="${grid}/.devcontainer/pane/container" \
            PANCAKE_TMUX_ROW="$2" \
            PANCAKE_TMUX_PANES_FILE="${grid}/.devcontainer/pane/$3" \
            PANCAKE_TMUX_DETACH_STATUS="${4:-}" zsh -i \
            > /dev/null 2> "${grid}/pane.err")
}
run_grid_pane() {
    rm -f "${grid}/pane.out"
    run_pane_shell exit "$1" "$2" || true
    cat "${grid}/pane.out" 2>/dev/null || true
}
# The runtime's container shell is zsh, which both the image and a macOS host
# have. Where it is absent these checks report the skip rather than passing
# quietly.
have_zsh=false
if command -v zsh > /dev/null; then
    have_zsh=true
else
    echo "test/host-invariants: skipping the pane runtime checks: zsh is not on PATH" >&2
fi

if [[ "${have_zsh}" == true ]]; then
    [[ "$(run_grid_pane 1 panes.sh)" == top ]]
    # An undeclared row is a plain shell, which is a stronger claim than an
    # empty result file: a pane that tried to run pane2 and failed also
    # writes nothing, and the reader would see the attempt in the pane.
    if [[ -n "$(run_grid_pane 2 panes.sh)" ]] ||
        grep -q pane2 "${grid}/pane.err"; then
        echo "test/host-invariants: an undeclared pane function ran a command" >&2
        exit 1
    fi
    [[ "$(run_grid_pane 3 panes.sh)" == bottom ]]
    [[ "$(run_grid_pane 1 panes-review.sh)" == review ]]
    [[ "$(wc -l < "${grid}/shared.count" | tr -d ' ')" -eq 3 ]]

    # Leaving the container is the runtime's one wire between its two shells:
    # the status the host half declares and hands over is the status this
    # shell exits with. 89 is that status, and pane/host/.bashrc owns it.
    pane_exit_status=0
    run_pane_shell pancake_devcontainer_exit 1 panes.sh 89 || pane_exit_status=$?
    if [[ "${pane_exit_status}" -ne 89 ]]; then
        echo "test/host-invariants: pancake_devcontainer_exit reported ${pane_exit_status}, not the detach status" >&2
        exit 1
    fi

    # Handed no status, there is no host shell waiting, so the verb refuses
    # rather than ending the shell on a guess: whatever this shell reports,
    # it is not the one status a waiting host shell reads as a detach.
    pane_exit_status=0
    run_pane_shell pancake_devcontainer_exit 1 panes.sh || pane_exit_status=$?
    if [[ "${pane_exit_status}" -eq 89 ]]; then
        echo "test/host-invariants: pancake_devcontainer_exit detached a shell no pane opened" >&2
        exit 1
    fi
fi

# What the pane does when its container shell ends is the host half's whole
# job, and it is decidable without docker: a checkout carrying a stub
# container lookup, and a docker that reports the status under test. A pane
# that survives runs the command fed after it, and a pane that ends never
# reaches it.
runtime="${scratch}/runtime"
mkdir -p "${runtime}/.devcontainer/pane/host" "${runtime}/bin"
cp "${dir}/pane/host/.bashrc" "${runtime}/.devcontainer/pane/host/.bashrc"
mkdir -p "${runtime}/.devcontainer/bin"
cat > "${runtime}/.devcontainer/bin/container-id.sh" <<'EOF'
printf 'stub-container\n'
EOF
cat > "${runtime}/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit "${PANCAKE_TEST_CONTAINER_STATUS}"
EOF
chmod +x "${runtime}/bin/docker"
runtime_status=0
run_pane_runtime() {
    rm -f "${runtime}/alive.out"
    runtime_status=0
    (cd "${runtime}" && printf 'echo alive > alive.out\nexit\n' |
        HOME="${runtime}" PATH="${runtime}/bin:${PATH}" \
            PANCAKE_TEST_CONTAINER_STATUS="$1" \
            bash --rcfile .devcontainer/pane/host/.bashrc -i > /dev/null 2>&1) ||
        runtime_status=$?
}
expect_pane_kept() {
    run_pane_runtime "$1"
    if [[ ! -f "${runtime}/alive.out" ]]; then
        echo "test/host-invariants: a container shell reporting $1 took the pane with it" >&2
        exit 1
    fi
}
expect_pane_ended() {
    run_pane_runtime "$1"
    if [[ -f "${runtime}/alive.out" ]]; then
        echo "test/host-invariants: a container shell reporting $1 left the pane behind" >&2
        exit 1
    fi
    if [[ "${runtime_status}" -ne "$1" ]]; then
        echo "test/host-invariants: a pane ending on $1 reported ${runtime_status}" >&2
        exit 1
    fi
}
# The host half is bash, so these run wherever this script does.
# The detach status keeps the pane, which is the whole point of the runtime.
expect_pane_kept 89
# So does a shell docker could not start, and a shell a signal ended: neither
# is the reader saying they are done, and a rebuilt container is re-entered
# from the pane that was waiting.
expect_pane_kept 125
expect_pane_kept 137
# Every other status is the shell ending on its own terms, and the pane goes
# with it carrying that status, as it did before the runtime.
expect_pane_ended 0
expect_pane_ended 3

# A column older than this pane runtime still uses this launcher's lookup,
# with that checkout named as an argument.
cat > "${runtime}/.devcontainer/bin/container-id.sh" <<'EOF'
printf '%s\n' "${1-}" > "${PANCAKE_TEST_ID_LOG}"
printf 'stub-container\n'
EOF
mkdir -p "${scratch}/old-column"
rm -f "${runtime}/id.log"
(cd "${runtime}" && printf 'exit\n' |
    HOME="${runtime}" PATH="${runtime}/bin:${PATH}" \
        PANCAKE_TEST_CONTAINER_STATUS=89 \
        PANCAKE_TEST_ID_LOG="${runtime}/id.log" \
        PANCAKE_TMUX_CHECKOUT="${scratch}/old-column" \
        bash --rcfile .devcontainer/pane/host/.bashrc -i > /dev/null 2>&1) || true
[[ "$(cat "${runtime}/id.log")" == "${scratch}/old-column" ]]

# The panes file also decides its column's row count, by textual scan.
[[ "$(pancake_devcontainer_grid_rows "${grid}/.devcontainer/pane/panes.sh")" == 3 ]]
[[ "$(pancake_devcontainer_grid_rows "${grid}/.devcontainer/pane/panes-review.sh")" == 1 ]]
[[ "$(pancake_devcontainer_grid_rows "${grid}/.devcontainer/pane/absent.sh")" == 0 ]]
printf 'function pane5() { :; }\n' > "${grid}/.devcontainer/pane/panes-tall.sh"
[[ "$(pancake_devcontainer_grid_rows "${grid}/.devcontainer/pane/panes-tall.sh")" == 5 ]]

rm "${grid}/.devcontainer/pane/panes.sh"
if [[ "${have_zsh}" == true && -n "$(run_grid_pane 1 panes.sh)" ]]; then
    echo "test/host-invariants: a missing panes.sh ran a command" >&2
    exit 1
fi
if bash "${dir}/bin/up.sh" --rebuild unexpected >/dev/null 2>&1; then
    echo "test/host-invariants: up.sh ignored an extra argument" >&2
    exit 1
fi

primary="${scratch}/repo #cash\$ O'Neil"
linked="${scratch}/tree1"
git init -q "${primary}"
git -C "${primary}" config user.email test@pancake.invalid
git -C "${primary}" config user.name "pancake test"
git -C "${primary}" config commit.gpgsign false
touch "${primary}/seed"
git -C "${primary}" add seed
git -C "${primary}" commit -qm seed
git -C "${primary}" worktree add -q -b test-tree1 "${linked}"
mkdir -p "${primary}/.devcontainer" "${linked}/.devcontainer"

printf 'PANCAKE_WORKTREE=main\n' > "${primary}/.devcontainer/.env"
if pancake_devcontainer_configure_env "${primary}/.devcontainer" >/dev/null 2>&1; then
    echo "test/host-invariants: configure accepted an incomplete existing environment" >&2
    exit 1
fi
rm "${primary}/.devcontainer/.env"
pancake_devcontainer_configure_env "${primary}/.devcontainer" >/dev/null 2>&1
expected_common="$(git -C "${primary}" rev-parse --path-format=absolute --git-common-dir)"
[[ "$(pancake_devcontainer_env_value "${primary}/.devcontainer" PANCAKE_WORKTREE)" == main ]]
[[ "$(pancake_devcontainer_env_value "${primary}/.devcontainer" EGRESS_NET)" == pancake-main-egress ]]
[[ "$(pancake_devcontainer_env_value "${primary}/.devcontainer" PANCAKE_GIT_COMMON_DIR)" == "${expected_common}" ]]
pancake_devcontainer_configure_env "${primary}/.devcontainer" 10000 other-network >/dev/null 2>&1
[[ "$(pancake_devcontainer_env_value "${primary}/.devcontainer" EGRESS_NET)" == pancake-main-egress ]]

# An .env the port table has outgrown is completed at the offset it already
# uses, and nothing else in it moves. This is what a checkout written before
# a port row existed meets, and deleting the operator's file is not the
# remedy on offer.
outgrown_env="${primary}/.devcontainer/.env"
docs_port_line="$(grep '^PANCAKE_DOCS_HOST_PORT=' "${outgrown_env}")"
[[ "${docs_port_line}" == PANCAKE_DOCS_HOST_PORT=1990 ]]
grep -v '^PANCAKE_DOCS_HOST_PORT=' "${outgrown_env}" > "${outgrown_env}.trimmed"
mv "${outgrown_env}.trimmed" "${outgrown_env}"
printf 'OPERATOR_ADDED=kept\n' >> "${outgrown_env}"
pancake_devcontainer_complete_env "${primary}/.devcontainer" 2>/dev/null
[[ "$(pancake_devcontainer_env_value "${primary}/.devcontainer" PANCAKE_DOCS_HOST_PORT)" == 1990 ]]
[[ "$(pancake_devcontainer_env_value "${primary}/.devcontainer" OPERATOR_ADDED)" == kept ]]

# The offset comes from the rows the file carries, not from the table.
offset_env="${scratch}/offset/.devcontainer"
mkdir -p "${offset_env}"
{
    printf 'PANCAKE_WORKTREE=tree1\n'
    printf 'PANCAKE_ROOMS_WEB_HOST_PORT=18000\n'
    printf 'PANCAKE_ROOMS_CAPTP_HOST_PORT=19099\n'
} > "${offset_env}/.env"
pancake_devcontainer_complete_env "${offset_env}" 2>/dev/null
[[ "$(pancake_devcontainer_env_value "${offset_env}" PANCAKE_DOCS_HOST_PORT)" == 11990 ]]

# Two offsets in one file is not something to guess about.
printf 'PANCAKE_ROOMS_RELAY_HOST_PORT=9200\n' >> "${offset_env}/.env"
if pancake_devcontainer_complete_env "${offset_env}" 2>/dev/null; then
    echo "test/host-invariants: completion guessed at a file with two port offsets" >&2
    exit 1
fi

# A file carrying no ports at all is not an outgrown one, so completion adds
# nothing and ordinary validation keeps the refusal.
bare_env="${scratch}/bare/.devcontainer"
mkdir -p "${bare_env}"
printf 'PANCAKE_WORKTREE=main\n' > "${bare_env}/.env"
pancake_devcontainer_complete_env "${bare_env}" 2>/dev/null
[[ "$(wc -l < "${bare_env}/.env" | tr -d ' ')" -eq 1 ]]
[[ "$(pancake_devcontainer_worktree_name "${primary}/.devcontainer")" == main ]]
pancake_devcontainer_validate_worktree "${primary}/.devcontainer" main

if pancake_devcontainer_worktree_name "${linked}/.devcontainer" >/dev/null 2>&1; then
    echo "test/host-invariants: an incomplete worktree environment acquired an implicit identity" >&2
    exit 1
fi

if pancake_devcontainer_configure_env "${linked}/.devcontainer" >/dev/null 2>&1; then
    echo "test/host-invariants: linked worktree guessed its host ports" >&2
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
    echo "test/host-invariants: linked worktree accepted the main identity" >&2
    exit 1
fi
if pancake_devcontainer_validate_worktree "${primary}/.devcontainer" tree1 >/dev/null 2>&1; then
    echo "test/host-invariants: primary checkout accepted a linked identity" >&2
    exit 1
fi

[[ "$(pancake_devcontainer_checkout_for_worktree "${primary}" tree1)" == "${linked}" ]]
[[ "$(pancake_devcontainer_registered_worktrees "${primary}" | tr '\n' ':')" == "main:tree1:" ]]
if pancake_devcontainer_checkout_for_worktree "${primary}" missing >/dev/null 2>&1; then
    echo "test/host-invariants: lookup invented an unregistered worktree" >&2
    exit 1
fi

# Worktrees sit on different branches, so a column may still keep up.sh
# beside compose. The launcher finds either spelling, and prefers bin/.
printf '#!/usr/bin/env bash\n' > "${linked}/.devcontainer/up.sh"
chmod +x "${linked}/.devcontainer/up.sh"
[[ "$(pancake_devcontainer_checkout_entry "${linked}" up.sh)" == "${linked}/.devcontainer/up.sh" ]]
[[ "$(pancake_devcontainer_resolve_checkout enter-grid.sh "${primary}" tree1)" == "${linked}" ]]
mkdir -p "${primary}/.devcontainer/bin"
printf '#!/usr/bin/env bash\n' > "${primary}/.devcontainer/bin/up.sh"
printf '#!/usr/bin/env bash\n' > "${primary}/.devcontainer/up.sh"
chmod +x "${primary}/.devcontainer/bin/up.sh" "${primary}/.devcontainer/up.sh"
[[ "$(pancake_devcontainer_checkout_entry "${primary}" up.sh)" == "${primary}/.devcontainer/bin/up.sh" ]]
noup="${scratch}/noup"
mkdir -p "${noup}/.devcontainer"
if pancake_devcontainer_checkout_entry "${noup}" up.sh >/dev/null 2>&1; then
    echo "test/host-invariants: found up.sh on a checkout that has none" >&2
    exit 1
fi
pane_cmd="$(pancake_devcontainer_pane_shell_command "${linked}" tree1 panes.sh 2)"
[[ "${pane_cmd}" == *"PANCAKE_TMUX_CHECKOUT="* ]]
[[ "${pane_cmd}" == *"${dir}/pane/host/.bashrc"* ]]
[[ "${pane_cmd}" != *"${linked}/.devcontainer/pane/host/.bashrc"* ]]

# Test doubles for the one external command the library calls. Each is
# reached through a library function rather than named here, which is the
# indirect invocation SC2317 asks about.
fake_docker_output=abc123
# shellcheck disable=SC2317
docker() {
    printf '%s\n' "${fake_docker_output}"
}
[[ "$(pancake_devcontainer_running_container "${primary}")" == abc123 ]]
fake_docker_output=$'abc123\ndef456'
if pancake_devcontainer_running_container "${primary}" >/dev/null 2>&1; then
    echo "test/host-invariants: ambiguous container labels selected one container" >&2
    exit 1
fi
unset -f docker

network_exists=false
network_created=""
# shellcheck disable=SC2317
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
    echo "test/host-invariants: startup created an operator-owned external network" >&2
    exit 1
fi
unset -f docker

if PANCAKE_WORKTREE=other pancake_devcontainer_validate_effective_env "${primary}/.devcontainer" >/dev/null 2>&1; then
    echo "test/host-invariants: inherited Compose identity bypassed .env" >&2
    exit 1
fi
PANCAKE_WORKTREE=main pancake_devcontainer_validate_effective_env "${primary}/.devcontainer"

cat >> "${primary}/.devcontainer/.env" <<'EOF'
PANCAKE_ROOMS_WEB_HOST_PORT=08000
PANCAKE_ROOMS_CAPTP_HOST_PORT=8000
EOF
if pancake_devcontainer_validate_host_ports "${primary}/.devcontainer" >/dev/null 2>&1; then
    echo "test/host-invariants: equivalent decimal ports were not treated as duplicates" >&2
    exit 1
fi
