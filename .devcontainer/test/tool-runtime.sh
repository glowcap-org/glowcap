#!/usr/bin/env bash
# Offline black-box proof of the managed-tool lifecycle and forwarding for
# `zig build infrastructure-check`. Stub drivers, stub release metadata, and
# stub package behavior exercise the real dispatcher, management front, and
# lifecycle: the code under test is never stubbed. No network, and no writes
# to the real shared cache or any credential store.
#
# Platform routing: the lifecycle needs flock (util-linux), GNU sort -V, and
# a current Bash, so this proof runs inside the Linux devcontainer. On any
# other host, including the macOS CI job, it prints one visible skip line
# and exits 0 before loading any Linux-only code. The skip must stay visible
# in successful output.
#
# Cases: cold/warm invocation,
# forwarding fidelity, seed adoption and retention, update failure paths,
# cross-process exclusion and interruption, repair and immutability,
# platform separation and malformed state, interception forms, receipts, and
# recovery-oriented failure reporting with multi-tool aggregation.

set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${GLOWCAP_DEVCONTAINER_DIR:-}" || "$(uname -s)" != "Linux" ]]; then
    echo "tool-runtime: skipped outside the Linux devcontainer (needs flock, GNU sort -V, bash >= 4)"
    exit 0
fi

failures=0
checks=0
scratch=""
pass() {
    checks=$((checks + 1))
}
fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    echo "tool-runtime: FAIL: $1" >&2
}
expect_rc() {
    local wanted="$1" label="$2"
    shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    if [[ "${rc}" == "${wanted}" ]]; then
        pass
    else
        fail "${label}: expected exit ${wanted}, got ${rc}"
    fi
}
expect_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        pass
    else
        fail "${label}: expected '${needle}' in: ${haystack}"
    fi
}
expect_file() {
    if [[ -e "$2" ]]; then
        pass
    else
        fail "$1: expected ${2} to exist"
    fi
}
expect_no_file() {
    if [[ ! -e "$2" ]]; then
        pass
    else
        fail "$1: expected ${2} to be absent"
    fi
}
expect_zero() {
    expect_rc 0 "$@"
}

cleanup() {
    if [[ -n "${slow_pid:-}" ]]; then
        kill "${slow_pid}" 2>/dev/null || true
        wait "${slow_pid}" 2>/dev/null || true
    fi
    if [[ -n "${scratch}" ]]; then
        chmod -R u+w "${scratch}" 2>/dev/null || true
        rm -rf "${scratch}"
    fi
}
trap cleanup EXIT

scratch="$(mktemp -d)"
sandbox="${scratch}/devcontainer"
platform="linux-$(uname -m)"

# ---------------------------------------------------------------------------
# Sandbox: a copy of the real tools runtime with a stub registry, stub pins,
# and stub drivers. The copied lifecycle, wrapper, and front are the code
# under test; only their inputs are stubbed.
# ---------------------------------------------------------------------------
mkdir -p "${sandbox}/bin"
cp -R "${dir}/lib" "${sandbox}/lib"
cp -R "${dir}/tools" "${sandbox}/tools"
cp "${dir}/bin/tools.sh" "${sandbox}/bin/tools.sh"
cp "${dir}/pins.sh" "${dir}/checksums.sh" "${sandbox}/"
cat >> "${sandbox}/pins.sh" <<'PINS'

# Test-only stub seeds; the offline test owns its sandbox registry.
STUB_A_VERSION="1.0.0"
STUB_B_VERSION="2.0.0"
STUB_FAIL_VERSION="3.0.0"
STUB_MISMATCH_VERSION="4.0.0"
STUB_BADVERIFY_VERSION="5.0.0"
STUB_SLOW_VERSION="6.0.0"
STUB_PINNED_VERSION="7.0.0"
PINS
cat > "${sandbox}/tools/lib/registry-rows-override.sh" <<'REG'
# Sandbox rows, appended after the real registry module: the later
# definition wins, and every other registry function stays real.
glowcap_tools_registry_rows() {
    printf '%s\n' \
        "stub-a|stub-a|STUB_A_VERSION|stub-a" \
        "stub-b|stub-b|STUB_B_VERSION|stub-b" \
        "stub-fail|stub-fail|STUB_FAIL_VERSION|stub-fail" \
        "stub-mismatch|stub-mismatch|STUB_MISMATCH_VERSION|stub-mismatch" \
        "stub-badverify|stub-badverify|STUB_BADVERIFY_VERSION|stub-badverify" \
        "stub-slow|stub-slow|STUB_SLOW_VERSION|stub-slow" \
        "stub-pinned|-|STUB_PINNED_VERSION|stub-pinned|pinned"
}
REG
cat "${sandbox}/tools/lib/registry-rows-override.sh" >> "${sandbox}/tools/lib/registry.sh"
rm -f "${sandbox}/tools/lib/registry-rows-override.sh"
# Stub release channel: values come from the environment; validation stays
# with the real glowcap_pins_latest_version. Appended last: later wins.
cat >> "${sandbox}/lib/update-pins-deps.sh" <<'QRY'
glowcap_pins_query_version() {
    local dep="$1" var
    var="STUB_LATEST_$(printf '%s' "${dep}" | tr 'a-z-' 'A-Z_')"
    printf '%s\n' "${!var:-}"
}
QRY

# The reference stub driver: contract-compliant (stdout unused, stdin read
# to EOF, all output on stderr), with a tool body that exercises forwarding.
cat > "${sandbox}/tools/lib/stub-a.sh" <<'DRV'
glowcap_tools_stub_a_download() {
    local version="$1" install_dir="$2"
    if ! mkdir -p "${install_dir}"; then return 1; fi
    if ! read -r stdin_probe; then
        printf 'installer-read: eof\n' >&2
    else
        printf 'installer-read: consumed stdin\n' >&2
    fi
    cat > "${install_dir}/stub-a-bin" <<BIN || return 1
#!/bin/sh
printf '%s\n' "stub-a-${version} args:\$* env:\${STUB_A_EXEC_ENV:-unset}"
case "\${1-}" in
    exit-42) exit 42 ;;
    stderr-probe) printf '%s\n' "tool-stderr-line" >&2 ;;
    stdin-probe) IFS= read -r input; printf 'input:%s\\n' "\${input}" ;;
    sleep-30) exec sleep 30 ;;
    pwd) exec pwd ;;
esac
BIN
    chmod +x "${install_dir}/stub-a-bin" || return 1
    printf 'installer-output-on-stderr\n' >&2
    GLOWCAP_TOOLS_SOURCE_URL="stub://${version}"
    GLOWCAP_TOOLS_VERIFICATION="none"
    GLOWCAP_TOOLS_EXPECTED_SHA=""
    GLOWCAP_TOOLS_OBSERVED_SHA="deadbeef"
}
glowcap_tools_stub_a_verify() {
    local install_dir="$1" version="$2" out
    [[ -x "${install_dir}/stub-a-bin" ]] || return 1
    out="$("${install_dir}/stub-a-bin" --version)" || return 1
    [[ "${out}" == "stub-a-${version} args:--version env:unset" ]]
}
glowcap_tools_stub_a_exec_path() {
    local install_dir="$1"
    [[ -x "${install_dir}/stub-a-bin" ]] || return 1
    printf '%s\n' "${install_dir}/stub-a-bin"
}
glowcap_tools_stub_a_exec_env() {
    printf '%s\n' "STUB_A_EXEC_ENV=1"
}
glowcap_tools_stub_a_intercept() {
    case "${1:-}" in
        update)
            if [[ "$#" -eq 1 ]]; then
                printf 'update\n'
            elif [[ "$2" == -h || "$2" == --help ]]; then
                printf 'help\n'
            else
                printf 'refuse:stub-a update options are managed by the front\n'
            fi
            ;;
        purge)
            printf 'refuse:stub-a purge would remove shared installs\n'
            ;;
        *)
            printf 'pass\n'
            ;;
    esac
}
DRV
cat > "${sandbox}/tools/lib/stub-b.sh" <<'DRV'
glowcap_tools_stub_b_download() {
    local version="$1" install_dir="$2"
    mkdir -p "${install_dir}" || return 1
    printf '#!/bin/sh\nprintf "stub-b-%s args:%%s\\n" "$*"\n' "${version}" > "${install_dir}/stub-b-bin" || return 1
    chmod +x "${install_dir}/stub-b-bin" || return 1
    GLOWCAP_TOOLS_SOURCE_URL="stub://${version}"
    GLOWCAP_TOOLS_VERIFICATION="none"
    GLOWCAP_TOOLS_EXPECTED_SHA=""
    GLOWCAP_TOOLS_OBSERVED_SHA=""
}
glowcap_tools_stub_b_verify() {
    local out
    out="$($1/stub-b-bin --version)" || return 1
    [[ "${out}" == "stub-b-$2 args:--version" ]]
}
glowcap_tools_stub_b_exec_path() { printf '%s\n' "$1/stub-b-bin"; }
glowcap_tools_stub_b_intercept() { printf 'pass\n'; }
DRV
cat > "${sandbox}/tools/lib/stub-pinned.sh" <<'DRV'
glowcap_tools_stub_pinned_download() {
    local version="$1" install_dir="$2"
    mkdir -p "${install_dir}" || return 1
    printf '#!/bin/sh\nprintf "stub-pinned-%s env:%%s\\n" "${STUB_PINNED_BROWSERS-}"\n' "${version}" > "${install_dir}/stub-pinned-bin" || return 1
    chmod +x "${install_dir}/stub-pinned-bin" || return 1
    GLOWCAP_TOOLS_SOURCE_URL="stub://${version}"
    GLOWCAP_TOOLS_VERIFICATION="none"
    GLOWCAP_TOOLS_EXPECTED_SHA=""
    GLOWCAP_TOOLS_OBSERVED_SHA=""
}
glowcap_tools_stub_pinned_verify() {
    [[ -x "$1/stub-pinned-bin" ]]
}
glowcap_tools_stub_pinned_exec_path() { printf '%s\n' "$1/stub-pinned-bin"; }
glowcap_tools_stub_pinned_exec_env() {
    printf '%s\n' "STUB_PINNED_BROWSERS=$1/browser"
}
DRV
cat > "${sandbox}/tools/lib/stub-fail.sh" <<'DRV'
glowcap_tools_stub_fail_download() {
    echo "stub-fail download exploded" >&2
    return 1
}
glowcap_tools_stub_fail_verify() { return 1; }
glowcap_tools_stub_fail_exec_path() { return 1; }
DRV
cat > "${sandbox}/tools/lib/stub-mismatch.sh" <<'DRV'
glowcap_tools_stub_mismatch_download() {
    local version="$1" install_dir="$2"
    mkdir -p "${install_dir}" || return 1
    printf '#!/bin/sh\nexit 0\n' > "${install_dir}/bin" || return 1
    chmod +x "${install_dir}/bin" || return 1
    GLOWCAP_TOOLS_SOURCE_URL="stub://${version}"
    GLOWCAP_TOOLS_VERIFICATION="checksum"
    GLOWCAP_TOOLS_EXPECTED_SHA="1111"
    GLOWCAP_TOOLS_OBSERVED_SHA="2222"
}
glowcap_tools_stub_mismatch_verify() { return 0; }
glowcap_tools_stub_mismatch_exec_path() { printf '%s\n' "$1/bin"; }
DRV
cat > "${sandbox}/tools/lib/stub-badverify.sh" <<'DRV'
glowcap_tools_stub_badverify_download() {
    local version="$1" install_dir="$2"
    mkdir -p "${install_dir}" || return 1
    printf '#!/bin/sh\nexit 0\n' > "${install_dir}/bin" || return 1
    chmod +x "${install_dir}/bin" || return 1
    GLOWCAP_TOOLS_SOURCE_URL="stub://${version}"
    GLOWCAP_TOOLS_VERIFICATION="none"
    GLOWCAP_TOOLS_EXPECTED_SHA=""
    GLOWCAP_TOOLS_OBSERVED_SHA=""
}
glowcap_tools_stub_badverify_verify() { return 1; }
glowcap_tools_stub_badverify_exec_path() { printf '%s\n' "$1/bin"; }
DRV
cat > "${sandbox}/tools/lib/stub-slow.sh" <<'DRV'
glowcap_tools_stub_slow_download() {
    if [[ "${STUB_SLOW_FAST:-}" == 1 ]]; then
        echo "stub-slow download failed immediately" >&2
        return 1
    fi
    echo "stub-slow download is hanging" >&2
    sleep 6
    return 1
}
glowcap_tools_stub_slow_verify() { return 1; }
glowcap_tools_stub_slow_exec_path() { return 1; }
DRV

cache_root="${scratch}/installed"
bin_dir="${scratch}/bin"
mkdir -p "${bin_dir}"
for name in stub-a stub-b stub-fail stub-mismatch stub-badverify stub-slow; do
    ln -s "${sandbox}/tools/wrapper.sh" "${bin_dir}/${name}"
done

tools_env() {
    env -u STUB_A_EXEC_ENV \
        GLOWCAP_TOOLS_CACHE_ROOT="${GLOWCAP_TOOLS_CACHE_ROOT:-${cache_root}}" \
        GLOWCAP_TOOLS_LOCK_WAIT="${GLOWCAP_TOOLS_LOCK_WAIT:-30}" \
        PATH="${bin_dir}:/usr/bin:/bin" \
        "$@"
}
tools() {
    tools_env bash "${sandbox}/bin/tools.sh" "$@"
}
stub_dir() {
    printf '%s/%s/%s' "${cache_root}" "${platform}" "$1"
}

# ---------------------------------------------------------------------------
# Case 1: cold invocation installs only the requested tool; warm invocation
# is silent and runs no installer or verify work, even after a seed change.
# ---------------------------------------------------------------------------
out="$(printf 'tool input\n' | tools_env stub-a stdin-probe 2>"${scratch}/err1")"
err="$(cat "${scratch}/err1")"
expect_contains "cold run installs and runs the seed" "stub-a-1.0.0 args:stdin-probe" "${out}"
expect_contains "installation preserves the tool input" "input:tool input" "${out}"
expect_contains "cold run names first use" "first use" "${err}"
expect_contains "installer output stays on stderr" "installer-output-on-stderr" "${err}"
expect_contains "installer reads closed stdin to EOF" "installer-read: eof" "${err}"
if [[ "${out}" != *"installer-output"* ]]; then
    pass
else
    fail "installer output leaked into the tool's stdout: ${out}"
fi
expect_no_file "cold run installs only the requested tool" "$(stub_dir stub-b)/current"
out="$(tools_env stub-a warm 2>"${scratch}/err2")"
err="$(cat "${scratch}/err2")"
expect_contains "warm run output is the tool's" "stub-a-1.0.0 args:warm env:1" "${out}"
if [[ -z "${err}" ]]; then
    pass
else
    fail "warm run is not silent: ${err}"
fi
sed -i 's/STUB_A_VERSION="1.0.0"/STUB_A_VERSION="9.9.9"/' "${sandbox}/pins.sh"
out="$(tools_env stub-a warm-after-bump 2>&1)"
expect_contains "warm run retains the selection after a seed change" "args:warm-after-bump" "${out}"
if [[ "${out}" != *"installing"* ]]; then
    pass
else
    fail "warm run installed despite a warm selection: ${out}"
fi
sed -i 's/STUB_A_VERSION="9.9.9"/STUB_A_VERSION="1.0.0"/' "${sandbox}/pins.sh"

# ---------------------------------------------------------------------------
# Case 2: forwarding fidelity, arguments, empty args, exit status, streams,
# working directory, signals, and invocation outside the checkout.
# ---------------------------------------------------------------------------
out="$(tools_env stub-a --flag "arg with spaces" "" tail 2>/dev/null)"
expect_contains "argument list survives" "args:--flag arg with spaces  tail" "${out}"
expect_rc 42 "tool exit status survives forwarding" tools_env stub-a exit-42
mkdir -p "${scratch}/cwd-probe"
out="$(cd "${scratch}/cwd-probe" && tools_env stub-a pwd 2>/dev/null)"
expect_contains "working directory survives" "${scratch}/cwd-probe" "${out}"
out="$(tools_env stub-a stderr-probe 2>"${scratch}/err3")"
expect_contains "stdout carries tool stdout" "args:stderr-probe" "${out}"
expect_contains "stderr passes through separately" "tool-stderr-line" "$(cat "${scratch}/err3")"
tools_env stub-a sleep-30 &
slow_pid=$!
sleep 0.6
kill -TERM "${slow_pid}" 2>/dev/null
wait "${slow_pid}" 2>/dev/null
slow_rc=$?
if [[ "${slow_rc}" -eq 143 ]]; then
    pass
else
    fail "expected signal termination 143, got ${slow_rc}"
fi
out="$(cd / && tools_env stub-a outside 2>/dev/null)"
expect_contains "invocation outside the checkout works" "args:outside" "${out}"

# ---------------------------------------------------------------------------
# Case 3: ensure adopts a strictly newer seed, retains a newer installed
# release, and stays quiet when warm.
# ---------------------------------------------------------------------------
out="$(tools ensure stub-a 2>&1)"
if [[ -z "${out}" ]]; then
    pass
else
    fail "warm ensure is silent: ${out}"
fi
sed -i 's/STUB_A_VERSION="1.0.0"/STUB_A_VERSION="1.1.0"/' "${sandbox}/pins.sh"
out="$(tools ensure stub-a 2>&1)"
expect_contains "ensure adopts a newer seed" "adopting seed 1.1.0" "${out}"
sed -i 's/STUB_A_VERSION="1.1.0"/STUB_A_VERSION="1.0.0"/' "${sandbox}/pins.sh"
out="$(tools status stub-a 2>/dev/null)"
expect_contains "ensure retains the newer installed release" "1.1.0" "${out}"

# ---------------------------------------------------------------------------
# Case 4: update failure and refusal paths preserve the prior selection.
# ---------------------------------------------------------------------------
out="$(STUB_LATEST_STUB_A="1.2.0" tools update stub-a 2>&1)"
expect_contains "update installs the upstream latest" "installing 1.2.0" "${out}"
out="$(STUB_LATEST_STUB_A="1.2.0" tools update stub-a 2>&1)"
expect_contains "repeated update is a no-op" "is current" "${out}"
STUB_LATEST_STUB_A="1.2.0-rc1"
export STUB_LATEST_STUB_A
expect_rc 2 "malformed upstream metadata exits 2" tools update stub-a
unset STUB_LATEST_STUB_A
STUB_LATEST_STUB_A=
export STUB_LATEST_STUB_A
expect_rc 2 "empty upstream answer exits 2" tools update stub-a
unset STUB_LATEST_STUB_A
out="$(tools status stub-a 2>/dev/null)"
expect_contains "failed queries keep the selection" "1.2.0" "${out}"
STUB_LATEST_STUB_A="1.0.5"
export STUB_LATEST_STUB_A
expect_rc 0 "an older upstream is refused" tools update stub-a
unset STUB_LATEST_STUB_A
out="$(tools status stub-a 2>/dev/null)"
expect_contains "refused older update keeps the selection" "1.2.0" "${out}"
expect_rc 1 "a digest mismatch fails the install" tools ensure stub-mismatch
expect_no_file "digest mismatch publishes nothing" "$(stub_dir stub-mismatch)/current"
expect_rc 1 "a verify failure fails the install" tools ensure stub-badverify
expect_no_file "verify failure publishes nothing" "$(stub_dir stub-badverify)/current"
expect_rc 1 "a download failure fails the install" tools ensure stub-fail
out="$(tools ensure stub-fail 2>&1)"
expect_contains "download failure keeps the selection" "previous selection is unchanged" "${out}"

# ---------------------------------------------------------------------------
# Case 5: cross-process exclusion, concurrent updates, and interruption.
# ---------------------------------------------------------------------------
mkdir -p "$(stub_dir stub-b)"
flock "$(stub_dir stub-b)/lock" -c 'sleep 4' &
locker_pid=$!
sleep 0.4
out="$(GLOWCAP_TOOLS_LOCK_WAIT=1 tools ensure stub-b 2>&1)"
expect_contains "lock contention is reported with a retry" "holds the lock" "${out}"
GLOWCAP_TOOLS_LOCK_WAIT=1
export GLOWCAP_TOOLS_LOCK_WAIT
expect_rc 75 "lock contention exits 75" tools ensure stub-b
unset GLOWCAP_TOOLS_LOCK_WAIT
kill "${locker_pid}" 2>/dev/null
wait "${locker_pid}" 2>/dev/null || true
current_before="$(tools status stub-a 2>/dev/null | awk '/^stub-a/ { print $2 }')"
STUB_LATEST_STUB_A="1.0.1" tools update stub-a >/dev/null 2>&1 &
older_pid=$!
STUB_LATEST_STUB_A="1.3.0" tools update stub-a >/dev/null 2>&1 &
newer_pid=$!
wait "${older_pid}" 2>/dev/null || true
wait "${newer_pid}" 2>/dev/null || true
current_after="$(tools status stub-a 2>/dev/null | awk '/^stub-a/ { print $2 }')"
if [[ "${current_after}" == "1.3.0" || "${current_after}" == "${current_before}" ]]; then
    pass
else
    fail "concurrent updates regressed current: ${current_after}"
fi
# An interrupted install cleans its staging, keeps the selection, and the
# lock is released by the kernel. The front is backgrounded as a simple
# command so $! is the front process itself, not a wrapping subshell.
env -u STUB_A_EXEC_ENV GLOWCAP_TOOLS_CACHE_ROOT="${cache_root}" \
    GLOWCAP_TOOLS_LOCK_WAIT=30 PATH="${bin_dir}:/usr/bin:/bin" \
    bash "${sandbox}/bin/tools.sh" ensure stub-slow &
slow_pid=$!
sleep 1.2
kill -TERM "${slow_pid}" 2>/dev/null || true
wait "${slow_pid}" 2>/dev/null
slow_rc=$?
if [[ "${slow_rc}" -eq 143 ]]; then
    pass
else
    fail "interrupted front should exit on TERM (143), got ${slow_rc}"
fi
sleep 0.3
leftover="$(find "$(stub_dir stub-slow)" -maxdepth 1 -name '.staging-*' 2>/dev/null | wc -l)"
if [[ "${leftover}" -eq 0 ]]; then
    pass
else
    fail "interrupted install left staging behind: ${leftover}"
fi
GLOWCAP_TOOLS_LOCK_WAIT=3
STUB_SLOW_FAST=1
export GLOWCAP_TOOLS_LOCK_WAIT STUB_SLOW_FAST
out="$(tools ensure stub-slow 2>&1)"
unset GLOWCAP_TOOLS_LOCK_WAIT STUB_SLOW_FAST
expect_contains "the lock is free after interruption" "installing" "${out}"

# ---------------------------------------------------------------------------
# Case 6: repair supersedes a broken install with a fresh identity and a
# running process keeps its files.
# ---------------------------------------------------------------------------
expect_zero "repair succeeds on a healthy install (adopts it)" tools repair stub-a
running_out="$(tools_env stub-a long-running 2>/dev/null)"
expect_contains "the selection still answers after repair" "args:long-running" "${running_out}"
# Corrupt the selection, then repair it.
install_path="$(readlink -f "$(stub_dir stub-a)/current")"
chmod -R u+w "${install_path}" 2>/dev/null || true
rm -f "${install_path}/stub-a-bin"
out="$(tools status stub-a 2>/dev/null)"
expect_contains "a broken selection is reported" "malformed" "${out}"
expect_rc 1 "a broken selection fails the run" tools_env stub-a anything
expect_zero "repair supersedes the broken install" tools repair stub-a
out="$(tools_env stub-a repaired 2>/dev/null)"
expect_contains "repaired selection answers" "args:repaired" "${out}"

# ---------------------------------------------------------------------------
# Case 7: platform/cache separation and malformed-state refusals.
# ---------------------------------------------------------------------------
expect_file "selections live under the platform key" "$(stub_dir stub-a)/current"
root2="${scratch}/installed2"
mkdir -p "${root2}/${platform}/stub-a/installs/0.9.0-aaaa1111"
printf '#!/bin/sh\nprintf "stub-a-0.9.0 args:%%s\\n" "$*"\n' > "${root2}/${platform}/stub-a/installs/0.9.0-aaaa1111/stub-a-bin"
chmod +x "${root2}/${platform}/stub-a/installs/0.9.0-aaaa1111/stub-a-bin"
printf 'tool=stub-a\nversion=0.9.0\nplatform=%s\npolicy=seed\n' "${platform}" \
    > "${root2}/${platform}/stub-a/installs/0.9.0-aaaa1111/receipt"
ln -s "installs/0.9.0-aaaa1111" "${root2}/${platform}/stub-a/current"
out="$(GLOWCAP_TOOLS_CACHE_ROOT="${root2}" tools_env stub-a elsewhere 2>/dev/null)"
expect_contains "a different cache root selects its own install" "stub-a-0.9.0" "${out}"
# Escaping selection link is refused, never followed.
rm -f "$(stub_dir stub-b)/current"
ln -s "${scratch}/outside-target" "$(stub_dir stub-b)/current"
mkdir -p "${scratch}/outside-target"
out="$(tools_env stub-b anything 2>&1)"
expect_contains "escaping selection link is refused" "escapes this tool's installs" "${out}"
rm -f "$(stub_dir stub-b)/current"
# A real directory at current is an error.
mkdir -p "$(stub_dir stub-b)/current"
out="$(tools_env stub-b anything 2>&1)"
expect_contains "a real directory at current is refused" "'current' is a real directory" "${out}"
rm -rf "$(stub_dir stub-b)/current"
# A malformed receipt is distinct in status and refused at run time.
expect_zero "cold ensure stub-b" tools ensure stub-b
chmod -R u+w "$(readlink -f "$(stub_dir stub-b)/current")" 2>/dev/null || true
printf 'garbage\n' > "$(readlink -f "$(stub_dir stub-b)/current")/receipt"
out="$(tools status stub-b 2>/dev/null)"
expect_contains "malformed selection is reported distinctly" "malformed" "${out}"
expect_rc 1 "malformed selection fails the run" tools_env stub-b anything

# ---------------------------------------------------------------------------
# Case 8: interception forms cause no accidental effects.
# ---------------------------------------------------------------------------
out="$(STUB_LATEST_STUB_A="1.4.0" tools_env stub-a update 2>&1)"
expect_contains "bare update routes to the front and installs" "installing 1.4.0" "${out}"
out="$(tools_env stub-a update --help 2>&1)"
expect_contains "update help explains management" "managed by" "${out}"
expect_rc 64 "update options are refused, not dropped" tools_env stub-a update --force
expect_rc 64 "native removal verbs are refused" tools_env stub-a purge
out="$(tools status stub-a 2>/dev/null)"
expect_contains "refused forms had no effects" "1.4.0" "${out}"
out="$(tools_env stub-a "update the file" 2>/dev/null)"
expect_contains "prompt text that starts with the verb is passed through" "args:update the file" "${out}"
out="$(tools_env stub-a --flag update 2>/dev/null)"
expect_contains "global options shift the verb to the tool" "args:--flag update" "${out}"
out="$(tools_env stub-a -- update 2>/dev/null)"
expect_contains "end-of-options is passed through" "args:-- update" "${out}"

# ---------------------------------------------------------------------------
# Case 9: receipts carry real installation metadata.
# ---------------------------------------------------------------------------
receipt="$(cat "$(readlink -f "$(stub_dir stub-a)/current")/receipt")"
expect_contains "receipt names the tool" "tool=stub-a" "${receipt}"
expect_contains "receipt records the version" "version=1.4.0" "${receipt}"
expect_contains "receipt records the policy" "policy=upstream" "${receipt}"
expect_contains "receipt records verification" "verification=none" "${receipt}"
expect_contains "receipt records the platform" "platform=${platform}" "${receipt}"
expect_contains "receipt records the observed digest" "observed_sha256=deadbeef" "${receipt}"

out="$(tools status 2>/dev/null)"
stub_a_row="$(printf '%s\n' "${out}" | grep '^stub-a ')"
expect_contains "all-tools status loads every driver and validates" "1.4.0" "${stub_a_row}"
if [[ "${stub_a_row%%:*}" != *malformed* ]]; then
    pass
else
    fail "all-tools status reported a healthy install as malformed: ${stub_a_row}"
fi

# ---------------------------------------------------------------------------
# Case 10: multi-tool aggregation returns the first failure's status; the
# front refuses implicit installs and unknown names.
# ---------------------------------------------------------------------------
expect_rc 1 "multi-tool aggregate returns the first failure" tools ensure stub-fail stub-a
expect_rc 64 "mutating verbs need explicit tools" tools ensure
expect_rc 64 "unknown tool is a usage error" tools ensure no-such-tool
expect_rc 64 "repair needs exactly one tool" tools repair stub-a stub-b
out="$(tools status stub-a 2>/dev/null)"
expect_contains "aggregated runs still completed the healthy tool" "1.4.0" "${out}"

# ---------------------------------------------------------------------------
# Case 11: pinned policy, the requirement is the checkout's own pin, several
# requirements coexist in one cache, updates are refused, exec supplies the
# environment, and the receipt records the requirement it was installed for.
# ---------------------------------------------------------------------------
tools exec stub-pinned -- env >"${scratch}/pinned-cold" 2>"${scratch}/pinned-cold-err"
pinned_out="$(cat "${scratch}/pinned-cold")"
# The selection link resolves through to the immutable install, so the
# environment carries the install's own browser directory.
expect_contains "pinned exec installs the exact requirement" "STUB_PINNED_BROWSERS=${cache_root}/${platform}/stub-pinned/installs/7.0.0-" "${pinned_out}"
sed -i 's/STUB_PINNED_VERSION="7.0.0"/STUB_PINNED_VERSION="8.0.0"/' "${sandbox}/pins.sh"
tools ensure stub-pinned 2>"${scratch}/pinned-up-err"
expect_contains "a new requirement installs beside the old one" "8.0.0" "$(ls "${scratch}/installed/${platform}/stub-pinned/required")"
expect_file "the old requirement's install survives a new requirement" "${scratch}/installed/${platform}/stub-pinned/required/7.0.0/receipt"
expect_contains "the receipt records the requirement" "requirement=8.0.0" "$(cat "${scratch}/installed/${platform}/stub-pinned/required/8.0.0/receipt")"
expect_contains "the receipt records the pinned policy" "policy=pinned" "$(cat "${scratch}/installed/${platform}/stub-pinned/required/8.0.0/receipt")"
sed -i 's/STUB_PINNED_VERSION="8.0.0"/STUB_PINNED_VERSION="7.0.0"/' "${sandbox}/pins.sh"
tools ensure stub-pinned 2>/dev/null
expect_contains "the selection follows the requirement back" "stub-pinned-7.0.0" "$(tools exec stub-pinned -- "${scratch}/installed/${platform}/stub-pinned/required/7.0.0/stub-pinned-bin" 2>/dev/null)"
expect_contains "exactly the two requirements remain" "7.0.0
8.0.0" "$(ls "${scratch}/installed/${platform}/stub-pinned/required")"
expect_rc 64 "a pinned tool refuses update" tools update stub-pinned
out="$(tools update stub-pinned 2>&1)"
expect_contains "the pinned refusal names the pin updater" "update-pins.sh" "${out}"

echo "tool-runtime: ${checks} checks, ${failures} failures"
if [[ "${failures}" -gt 0 ]]; then
    exit 1
fi
