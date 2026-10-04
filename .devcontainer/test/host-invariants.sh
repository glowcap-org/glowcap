#!/usr/bin/env bash
# Self-contained tests for host-side configuration, identity, and lookup.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# lib/launcher.sh sources lib/mod.sh, so this covers both surfaces under test.
# shellcheck source=../lib/launcher.sh
source "${dir}/lib/launcher.sh"
# shellcheck source=../lib/playwright.sh
source "${dir}/lib/playwright.sh"

# These tests build checkouts of their own and configure them. Run inside a
# devcontainer, the surrounding checkout's identity is exported into this
# process, and `validate_effective_env` is right to refuse a fixture whose
# `.env` says something else — so the ambient identity is cleared here rather
# than the guard being weakened. The list is the one the guard reads.
while IFS= read -r glowcap_compose_variable; do
    unset "${glowcap_compose_variable}"
done < <(glowcap_devcontainer_compose_variables)
unset glowcap_compose_variable

scratch="$(mktemp -d)"
cleanup() {
    rm -rf -- "${scratch}"
}
trap cleanup EXIT

# Exercise release metadata before it becomes a version report or shell source.
(
    # shellcheck source=../lib/update-pins-deps.sh
    source "${dir}/lib/update-pins-deps.sh"
    glowcap_devcontainer_source_pins "${dir}"
    glowcap_pins_query_version() { printf '%s\n' "${query_fixture}"; }
    for dep in ${GLOWCAP_PINS_DEPS}; do
        var="$(glowcap_pins_dep_var "${dep}")"
        query_fixture="${!var}"
        [[ "$(glowcap_pins_latest_version "${dep}")" == "${query_fixture}" ]]
        for query_fixture in '' null '1.2.3-rc.1' '1.2.3"; false' $'1.2.3\n1.2.4'; do
            if glowcap_pins_latest_version "${dep}" >"${scratch}/query-output" 2>"${scratch}/query-error"; then
                echo "test/host-invariants: ${dep} accepted malformed release metadata" >&2
                exit 1
            fi
            [[ ! -s "${scratch}/query-output" ]]
            grep -Fq "${dep}: invalid upstream version" "${scratch}/query-error"
        done
    done
    glowcap_pins_query_version() { printf '1.2.3\n'; return 22; }
    if glowcap_pins_latest_version npm >"${scratch}/query-output"; then
        echo "test/host-invariants: accepted output from a failed upstream query" >&2
        exit 1
    fi
    [[ ! -s "${scratch}/query-output" ]]
)

# Playwright's Linux archives use different inner names on x86_64 and arm64.
# The image verifier must find one full browser and one headless shell on both,
# and must not accept a partial installation merely because one binary exists.
for playwright_layout in arm64 x86_64; do
    playwright_root="${scratch}/playwright-${playwright_layout}"
    if [[ "${playwright_layout}" == arm64 ]]; then
        chromium_rel="chromium-1234/chrome-linux-arm64/chrome"
        headless_rel="chromium_headless_shell-1234/chrome-headless-shell-linux-arm64/chrome-headless-shell"
    else
        chromium_rel="chromium-1234/chrome-linux64/chrome"
        headless_rel="chromium_headless_shell-1234/chrome-headless-shell-linux64/chrome-headless-shell"
    fi
    mkdir -p "${playwright_root}/${chromium_rel%/*}" "${playwright_root}/${headless_rel%/*}"
    touch "${playwright_root}/${chromium_rel}" "${playwright_root}/${headless_rel}"
    if ! glowcap_playwright_binaries "${playwright_root}"; then
        echo "test/host-invariants: Playwright resolver missed the ${playwright_layout} browser layout" >&2
        exit 1
    fi
    [[ "${playwright_bins[0]}" == "${playwright_root}/${chromium_rel}" ]]
    [[ "${playwright_bins[1]}" == "${playwright_root}/${headless_rel}" ]]
    rm "${playwright_root}/${headless_rel}"
    if glowcap_playwright_binaries "${playwright_root}"; then
        echo "test/host-invariants: Playwright resolver accepted a missing headless shell" >&2
        exit 1
    fi
done

# A pin bump that leaves the previous build number behind is ambiguous, not
# satisfied twice: the resolver refuses a store holding two full browsers.
playwright_root="${scratch}/playwright-stale"
mkdir -p "${playwright_root}/chromium-1111/chrome-linux64" \
    "${playwright_root}/chromium-2222/chrome-linux64" \
    "${playwright_root}/chromium_headless_shell-2222/chrome-headless-shell-linux64"
touch "${playwright_root}/chromium-1111/chrome-linux64/chrome" \
    "${playwright_root}/chromium-2222/chrome-linux64/chrome" \
    "${playwright_root}/chromium_headless_shell-2222/chrome-headless-shell-linux64/chrome-headless-shell"
if glowcap_playwright_binaries "${playwright_root}"; then
    echo "test/host-invariants: Playwright resolver accepted two full browsers" >&2
    exit 1
fi
unset playwright_layout playwright_root chromium_rel headless_rel playwright_bins

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
ln -s "${dir}/bin/enter.sh" "${scratch}/host/glowcap"
help_output="$(cd / && "${scratch}/host/glowcap" --help)"
[[ "${help_output}" == *"bash .devcontainer/bin/enter.sh tree1"* ]]
[[ "${help_output}" == *"--session review"* ]]

[[ "$(glowcap_devcontainer_tmux_session_name main)" == glowcap-dev-main ]]
[[ "$(glowcap_devcontainer_tmux_session_name main review)" == glowcap-dev-main-review ]]
[[ "$(glowcap_devcontainer_tmux_session_name tree1 investigation-2)" == glowcap-dev-tree1-investigation-2 ]]
glowcap_devcontainer_validate_session_designator review
glowcap_devcontainer_validate_session_designator investigation-2
glowcap_devcontainer_validate_session_designator abcdefghijklmnopqrstuvwx
for invalid_session in Review review_one review:one -review review- 123review; do
    if glowcap_devcontainer_validate_session_designator "${invalid_session}" >/dev/null 2>&1; then
        echo "test/host-invariants: accepted invalid session designator: ${invalid_session}" >&2
        exit 1
    fi
done
if glowcap_devcontainer_validate_session_designator abcdefghijklmnopqrstuvwxy >/dev/null 2>&1; then
    echo "test/host-invariants: accepted an overlong session designator" >&2
    exit 1
fi

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
if TERM_PROGRAM='' LC_TERMINAL='' glowcap_devcontainer_client_is_iterm2; then
    echo "test/host-invariants: a non-iTerm2 client was detected as iTerm2" >&2
    exit 1
fi
TERM_PROGRAM=iTerm.app glowcap_devcontainer_client_is_iterm2
TERM_PROGRAM='' LC_TERMINAL=iTerm2 glowcap_devcontainer_client_is_iterm2
grid_help_output="$(bash "${dir}/bin/enter-grid.sh" --help)"
[[ "${grid_help_output}" == *"columns: every registered worktree"* ]]
[[ "${grid_help_output}" == *"tmux: glowcap-dev-grid-review"* ]]

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
            GLOWCAP_TMUX_ROW="$2" \
            GLOWCAP_TMUX_PANES_FILE="${grid}/.devcontainer/pane/$3" \
            GLOWCAP_TMUX_DETACH_STATUS="${4:-}" zsh -i \
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
    run_pane_shell glowcap_devcontainer_exit 1 panes.sh 89 || pane_exit_status=$?
    if [[ "${pane_exit_status}" -ne 89 ]]; then
        echo "test/host-invariants: glowcap_devcontainer_exit reported ${pane_exit_status}, not the detach status" >&2
        exit 1
    fi

    # Handed no status, there is no host shell waiting, so the verb refuses
    # rather than ending the shell on a guess: whatever this shell reports,
    # it is not the one status a waiting host shell reads as a detach.
    pane_exit_status=0
    run_pane_shell glowcap_devcontainer_exit 1 panes.sh || pane_exit_status=$?
    if [[ "${pane_exit_status}" -eq 89 ]]; then
        echo "test/host-invariants: glowcap_devcontainer_exit detached a shell no pane opened" >&2
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
exit "${GLOWCAP_TEST_CONTAINER_STATUS}"
EOF
chmod +x "${runtime}/bin/docker"
runtime_status=0
run_pane_runtime() {
    rm -f "${runtime}/alive.out"
    runtime_status=0
    (cd "${runtime}" && printf 'echo alive > alive.out\nexit\n' |
        HOME="${runtime}" PATH="${runtime}/bin:${PATH}" \
            GLOWCAP_TEST_CONTAINER_STATUS="$1" \
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
printf '%s\n' "${1-}" > "${GLOWCAP_TEST_ID_LOG}"
printf 'stub-container\n'
EOF
mkdir -p "${scratch}/old-column"
rm -f "${runtime}/id.log"
(cd "${runtime}" && printf 'exit\n' |
    HOME="${runtime}" PATH="${runtime}/bin:${PATH}" \
        GLOWCAP_TEST_CONTAINER_STATUS=89 \
        GLOWCAP_TEST_ID_LOG="${runtime}/id.log" \
        GLOWCAP_TMUX_CHECKOUT="${scratch}/old-column" \
        bash --rcfile .devcontainer/pane/host/.bashrc -i > /dev/null 2>&1) || true
[[ "$(cat "${runtime}/id.log")" == "${scratch}/old-column" ]]

# The panes file also decides its column's row count, by textual scan.
[[ "$(glowcap_devcontainer_grid_rows "${grid}/.devcontainer/pane/panes.sh")" == 3 ]]
[[ "$(glowcap_devcontainer_grid_rows "${grid}/.devcontainer/pane/panes-review.sh")" == 1 ]]
[[ "$(glowcap_devcontainer_grid_rows "${grid}/.devcontainer/pane/absent.sh")" == 0 ]]
printf 'function pane5() { :; }\n' > "${grid}/.devcontainer/pane/panes-tall.sh"
[[ "$(glowcap_devcontainer_grid_rows "${grid}/.devcontainer/pane/panes-tall.sh")" == 5 ]]

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
git -C "${primary}" config user.email test@glowcap.invalid
git -C "${primary}" config user.name "glowcap test"
git -C "${primary}" config commit.gpgsign false
touch "${primary}/seed"
git -C "${primary}" add seed
git -C "${primary}" commit -qm seed
git -C "${primary}" worktree add -q -b test-tree1 "${linked}"
mkdir -p "${primary}/.devcontainer" "${linked}/.devcontainer"

# A linked worktree's submodule repository lives under the primary checkout's
# common Git directory. Bootstrap must leave an absolute core.worktree rather
# than Git's generated relative path, which points at /workspaces from only one
# side of the devcontainer boundary.
submodule_source="${scratch}/submodule-source"
submodule_primary="${scratch}/submodule-primary"
submodule_linked="${scratch}/submodule-linked"
git init -q "${submodule_source}"
git -C "${submodule_source}" config user.email test@glowcap.invalid
git -C "${submodule_source}" config user.name "glowcap test"
git -C "${submodule_source}" config commit.gpgsign false
touch "${submodule_source}/seed"
git -C "${submodule_source}" add seed
git -C "${submodule_source}" commit -qm seed
git init -q "${submodule_primary}"
git -C "${submodule_primary}" config user.email test@glowcap.invalid
git -C "${submodule_primary}" config user.name "glowcap test"
git -C "${submodule_primary}" config commit.gpgsign false
mkdir -p "${submodule_primary}/conformance"
cp "${dir}/../conformance/bootstrap-submodules.sh" "${submodule_primary}/conformance/"
for submodule_path in ocapn-conformance ocapn-spec syrup spritely-goblins; do
    git -C "${submodule_primary}" -c protocol.file.allow=always submodule add -q \
        "${submodule_source}" "conformance/${submodule_path}/upstream"
done
git -C "${submodule_primary}" add .
git -C "${submodule_primary}" commit -qm submodules

# Repair container-only pointers and stale reverse links before asking Git to
# update. Preserve local submodule edits, and keep a primary clone relocatable.
for submodule_path in ocapn-conformance ocapn-spec syrup spritely-goblins; do
    printf 'gitdir: /missing-container/.git/modules/conformance/%s/upstream\n' \
        "${submodule_path}" > "${submodule_primary}/conformance/${submodule_path}/upstream/.git"
    git config --file "${submodule_primary}/.git/modules/conformance/${submodule_path}/upstream/config" \
        core.worktree "/missing-container/conformance/${submodule_path}/upstream"
done
printf 'local edit\n' > "${submodule_primary}/conformance/syrup/upstream/seed"
bootstrap_log="${scratch}/bootstrap-submodules.log"
if ! GIT_ALLOW_PROTOCOL='file' bash "${submodule_primary}/conformance/bootstrap-submodules.sh" \
    >"${bootstrap_log}" 2>&1; then
    cat "${bootstrap_log}" >&2
    exit 1
fi
mv "${submodule_primary}" "${submodule_primary}-moved"
submodule_primary="${submodule_primary}-moved"
git -C "${submodule_primary}" status --short >/dev/null
[[ "$(git -C "${submodule_primary}/conformance/syrup/upstream" diff -- seed)" == *"+local edit"* ]]
if ! GIT_ALLOW_PROTOCOL='file' bash "${submodule_primary}/conformance/bootstrap-submodules.sh" \
    >"${bootstrap_log}" 2>&1; then
    cat "${bootstrap_log}" >&2
    exit 1
fi
for submodule_path in ocapn-conformance ocapn-spec syrup spritely-goblins; do
    git -C "${submodule_primary}/conformance/${submodule_path}/upstream" status --short >/dev/null
done
git -C "${submodule_primary}" worktree add -q -b submodule-linked "${submodule_linked}"
bootstrap_log="${scratch}/bootstrap-submodules.log"
if ! GIT_ALLOW_PROTOCOL='file' GLOWCAP_CHECKOUT_DIR="${submodule_linked}" \
    bash "${submodule_linked}/conformance/bootstrap-submodules.sh" >"${bootstrap_log}" 2>&1; then
    cat "${bootstrap_log}" >&2
    exit 1
fi
submodule_git_dir="$(git -C "${submodule_linked}" rev-parse --path-format=absolute --git-dir)"
for submodule_path in ocapn-conformance ocapn-spec syrup spritely-goblins; do
    submodule_store="${submodule_git_dir}/modules/conformance/${submodule_path}/upstream"
    [[ "$(cat "${submodule_linked}/conformance/${submodule_path}/upstream/.git")" == \
        "gitdir: ${submodule_store}" ]]
    [[ "$(git config --file "${submodule_store}/config" core.worktree)" == \
        "${submodule_linked}/conformance/${submodule_path}/upstream" ]]
done
git -C "${submodule_linked}" status --short >/dev/null
unset submodule_source submodule_primary submodule_linked submodule_path submodule_git_dir submodule_store

printf 'GLOWCAP_WORKTREE=main\n' > "${primary}/.devcontainer/.env"
if glowcap_devcontainer_configure_env "${primary}/.devcontainer" >/dev/null 2>&1; then
    echo "test/host-invariants: configure accepted an incomplete existing environment" >&2
    exit 1
fi
rm "${primary}/.devcontainer/.env"
# Reject a reservation conflict before creating a file, including an offset
# that makes a different development service land on production's HTTP port.
for reserved_offset in 1907 5090; do
    if glowcap_devcontainer_configure_env "${primary}/.devcontainer" "${reserved_offset}" >"${scratch}/reserved-port.log" 2>&1; then
        echo "test/host-invariants: configure accepted deployment port 8080" >&2
        exit 1
    fi
    grep -q '8080 is reserved' "${scratch}/reserved-port.log"
    [[ ! -e "${primary}/.devcontainer/.env" ]]
done
glowcap_devcontainer_configure_env "${primary}/.devcontainer" >/dev/null 2>&1
expected_common="$(git -C "${primary}" rev-parse --path-format=absolute --git-common-dir)"
[[ "$(glowcap_devcontainer_env_value "${primary}/.devcontainer" GLOWCAP_WORKTREE)" == main ]]
[[ "$(glowcap_devcontainer_env_value "${primary}/.devcontainer" GLOWCAP_ROOMS_WEB_HOST_PORT)" == 9080 ]]
[[ "$(glowcap_devcontainer_env_value "${primary}/.devcontainer" GLOWCAP_CHECKOUT_DIR)" == "${primary}" ]]
[[ "$(glowcap_devcontainer_env_value "${primary}/.devcontainer" EGRESS_NET)" == glowcap-dev-main-egress ]]
[[ "$(glowcap_devcontainer_env_value "${primary}/.devcontainer" GLOWCAP_GIT_COMMON_DIR)" == "${expected_common}" ]]
glowcap_devcontainer_configure_env "${primary}/.devcontainer" 10000 other-network >/dev/null 2>&1
[[ "$(glowcap_devcontainer_env_value "${primary}/.devcontainer" EGRESS_NET)" == glowcap-dev-main-egress ]]

# An .env the port table has outgrown is completed at the offset it already
# uses, and nothing else in it moves. This is what a checkout written before
# a port row existed meets, and deleting the operator's file is not the
# remedy on offer.
outgrown_env="${primary}/.devcontainer/.env"
docs_port_line="$(grep '^GLOWCAP_DOCS_HOST_PORT=' "${outgrown_env}")"
[[ "${docs_port_line}" == GLOWCAP_DOCS_HOST_PORT=2990 ]]
grep -v -e '^GLOWCAP_DOCS_HOST_PORT=' -e '^GLOWCAP_CHECKOUT_DIR=' \
    "${outgrown_env}" > "${outgrown_env}.trimmed"
mv "${outgrown_env}.trimmed" "${outgrown_env}"
printf 'OPERATOR_ADDED=kept\n' >> "${outgrown_env}"
glowcap_devcontainer_complete_env "${primary}/.devcontainer" 2>/dev/null
[[ "$(glowcap_devcontainer_env_value "${primary}/.devcontainer" GLOWCAP_CHECKOUT_DIR)" == "${primary}" ]]
[[ "$(glowcap_devcontainer_env_value "${primary}/.devcontainer" GLOWCAP_DOCS_HOST_PORT)" == 2990 ]]
[[ "$(glowcap_devcontainer_env_value "${primary}/.devcontainer" OPERATOR_ADDED)" == kept ]]

# The offset comes from the rows the file carries, not from the table. An old
# baseline remains usable: filling missing entries must not silently remap it.
offset_env="${scratch}/offset/.devcontainer"
mkdir -p "${offset_env}"
{
    printf 'GLOWCAP_WORKTREE=tree1\n'
    printf 'GLOWCAP_ROOMS_WEB_HOST_PORT=18080\n'
    printf 'GLOWCAP_ROOMS_CAPTP_HOST_PORT=19099\n'
} > "${offset_env}/.env"
glowcap_devcontainer_complete_env "${offset_env}" 2>/dev/null
[[ "$(glowcap_devcontainer_env_value "${offset_env}" GLOWCAP_DOCS_HOST_PORT)" == 11990 ]]

# Two offsets in one file is not something to guess about.
printf 'GLOWCAP_ROOMS_RELAY_HOST_PORT=9200\n' >> "${offset_env}/.env"
if glowcap_devcontainer_complete_env "${offset_env}" 2>/dev/null; then
    echo "test/host-invariants: completion guessed at a file with two port offsets" >&2
    exit 1
fi

# A file carrying no ports still gains the Git-owned checkout path, but it is
# not an outgrown port table, so ordinary validation keeps the refusal.
bare_env="${scratch}/bare/.devcontainer"
mkdir -p "${bare_env}"
printf 'GLOWCAP_WORKTREE=main\n' > "${bare_env}/.env"
glowcap_devcontainer_complete_env "${bare_env}" 2>/dev/null
[[ "$(glowcap_devcontainer_env_value "${bare_env}" GLOWCAP_CHECKOUT_DIR)" == "${scratch}/bare" ]]
[[ "$(wc -l < "${bare_env}/.env" | tr -d ' ')" -eq 2 ]]
[[ "$(glowcap_devcontainer_worktree_name "${primary}/.devcontainer")" == main ]]
glowcap_devcontainer_validate_worktree "${primary}/.devcontainer" main

if glowcap_devcontainer_worktree_name "${linked}/.devcontainer" >/dev/null 2>&1; then
    echo "test/host-invariants: an incomplete worktree environment acquired an implicit identity" >&2
    exit 1
fi

if glowcap_devcontainer_configure_env "${linked}/.devcontainer" >/dev/null 2>&1; then
    echo "test/host-invariants: linked worktree guessed its host ports" >&2
    exit 1
fi
glowcap_devcontainer_configure_env "${linked}/.devcontainer" 10000 >/dev/null 2>&1
[[ "$(glowcap_devcontainer_worktree_name "${linked}/.devcontainer")" == tree1 ]]
[[ "$(glowcap_devcontainer_env_value "${linked}/.devcontainer" GLOWCAP_CHECKOUT_DIR)" == "${linked}" ]]
[[ "$(glowcap_devcontainer_env_value "${linked}/.devcontainer" GLOWCAP_ROOMS_WEB_HOST_PORT)" == 19080 ]]
[[ "$(glowcap_devcontainer_env_value "${linked}/.devcontainer" GLOWCAP_DOCS_HOST_PORT)" == 12990 ]]
[[ "$(glowcap_devcontainer_env_value "${linked}/.devcontainer" EGRESS_NET)" == glowcap-dev-tree1-egress ]]
glowcap_devcontainer_validate_worktree "${linked}/.devcontainer" tree1
# Main must coexist with the established linked-worktree offsets. Compare
# every service against every other service, not just web against web.
allocated_ports="8080"
for port_offset in 0 10000 20000 30000; do
    while IFS=: read -r variable base; do
        port=$((base + port_offset))
        for allocated_port in ${allocated_ports}; do
            [[ "${port}" != "${allocated_port}" ]]
        done
        allocated_ports="${allocated_ports} ${port}"
    done <<< "$(glowcap_devcontainer_port_rows)"
done
# An existing operator file cannot give any development service port 8080,
# including a decimal with a leading zero. Validation leaves the file intact.
reserved_env="${scratch}/reserved-env"
mkdir -p "${reserved_env}"
while IFS=: read -r variable base; do
    cp "${primary}/.devcontainer/.env" "${reserved_env}/.env"
    printf '%s=08080\n' "${variable}" >> "${reserved_env}/.env"
    if glowcap_devcontainer_validate_host_ports "${reserved_env}" >"${scratch}/reserved-port.log" 2>&1; then
        echo "test/host-invariants: existing ${variable} claimed deployment port 8080" >&2
        exit 1
    fi
    grep -q '8080 is reserved' "${scratch}/reserved-port.log"
    [[ "$(glowcap_devcontainer_env_value "${reserved_env}" "${variable}")" == 08080 ]]
done
[[ "$(glowcap_devcontainer_primary_checkout "${linked}")" == "${primary}" ]]

if glowcap_devcontainer_validate_worktree "${linked}/.devcontainer" main >/dev/null 2>&1; then
    echo "test/host-invariants: linked worktree accepted the main identity" >&2
    exit 1
fi
if glowcap_devcontainer_validate_worktree "${primary}/.devcontainer" tree1 >/dev/null 2>&1; then
    echo "test/host-invariants: primary checkout accepted a linked identity" >&2
    exit 1
fi

[[ "$(glowcap_devcontainer_checkout_for_worktree "${primary}" tree1)" == "${linked}" ]]
[[ "$(glowcap_devcontainer_registered_worktrees "${primary}" | tr '\n' ':')" == "main:tree1:" ]]
if glowcap_devcontainer_checkout_for_worktree "${primary}" missing >/dev/null 2>&1; then
    echo "test/host-invariants: lookup invented an unregistered worktree" >&2
    exit 1
fi

# Worktrees sit on different branches, so a column may still keep up.sh
# beside compose. The launcher finds either spelling, and prefers bin/.
printf '#!/usr/bin/env bash\n' > "${linked}/.devcontainer/up.sh"
chmod +x "${linked}/.devcontainer/up.sh"
[[ "$(glowcap_devcontainer_checkout_entry "${linked}" up.sh)" == "${linked}/.devcontainer/up.sh" ]]
[[ "$(glowcap_devcontainer_resolve_checkout enter-grid.sh "${primary}" tree1)" == "${linked}" ]]
mkdir -p "${primary}/.devcontainer/bin"
printf '#!/usr/bin/env bash\n' > "${primary}/.devcontainer/bin/up.sh"
printf '#!/usr/bin/env bash\n' > "${primary}/.devcontainer/up.sh"
chmod +x "${primary}/.devcontainer/bin/up.sh" "${primary}/.devcontainer/up.sh"
[[ "$(glowcap_devcontainer_checkout_entry "${primary}" up.sh)" == "${primary}/.devcontainer/bin/up.sh" ]]
noup="${scratch}/noup"
mkdir -p "${noup}/.devcontainer"
if glowcap_devcontainer_checkout_entry "${noup}" up.sh >/dev/null 2>&1; then
    echo "test/host-invariants: found up.sh on a checkout that has none" >&2
    exit 1
fi
pane_cmd="$(glowcap_devcontainer_pane_shell_command "${linked}" tree1 panes.sh 2)"
[[ "${pane_cmd}" == *"GLOWCAP_TMUX_CHECKOUT="* ]]
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
[[ "$(glowcap_devcontainer_running_container "${primary}")" == abc123 ]]
fake_docker_output=$'abc123\ndef456'
if glowcap_devcontainer_running_container "${primary}" >/dev/null 2>&1; then
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
glowcap_devcontainer_ensure_network glowcap-dev-main-egress managed
[[ "${network_created}" == glowcap-dev-main-egress ]]
network_exists=false
if glowcap_devcontainer_ensure_network missing-external external >/dev/null 2>&1; then
    echo "test/host-invariants: startup created an operator-owned external network" >&2
    exit 1
fi
unset -f docker

if GLOWCAP_WORKTREE=other glowcap_devcontainer_validate_effective_env "${primary}/.devcontainer" >/dev/null 2>&1; then
    echo "test/host-invariants: inherited Compose identity bypassed .env" >&2
    exit 1
fi
GLOWCAP_WORKTREE=main glowcap_devcontainer_validate_effective_env "${primary}/.devcontainer"

cat >> "${primary}/.devcontainer/.env" <<'EOF'
GLOWCAP_ROOMS_WEB_HOST_PORT=08000
GLOWCAP_ROOMS_CAPTP_HOST_PORT=8000
EOF
if glowcap_devcontainer_validate_host_ports "${primary}/.devcontainer" >/dev/null 2>&1; then
    echo "test/host-invariants: equivalent decimal ports were not treated as duplicates" >&2
    exit 1
fi
