#!/usr/bin/env bash
# Black-box the agent build front and lease for `zig build infrastructure-check`.
#
# This test takes no arguments or configuration. It creates isolated fakes and
# lock files, emits only failures, and removes its processes and files on exit.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
container_dir="${repo_root}/.devcontainer"
front="${repo_root}/.agents/skills/work/bin/glowcap-dev"
lease_runner="${repo_root}/.agents/skills/work/bin/glowcap-build-lease"

if ! command -v python3 >/dev/null 2>&1; then
    echo "test/build-front: python3 is required to exercise the portable build lease" >&2
    exit 127
fi

scratch="$(mktemp -d)"
lease_owner_pid=""
lease_waiter_pid=""
cleanup() {
    if [[ -n "${lease_waiter_pid}" ]]; then
        kill "${lease_waiter_pid}" 2>/dev/null || true
        wait "${lease_waiter_pid}" 2>/dev/null || true
    fi
    if [[ -n "${lease_owner_pid}" ]]; then
        kill "${lease_owner_pid}" 2>/dev/null || true
        wait "${lease_owner_pid}" 2>/dev/null || true
    fi
    rm -rf -- "${scratch}"
}
trap cleanup EXIT

mkdir "${scratch}/bin"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == ps ]]; then printf "abc123\\n"; exit 0; fi' \
    'if [[ "$*" == "exec abc123 uname -m" ]]; then printf "%s\\n" "${FAKE_CONTAINER_ARCH:-$(uname -m)}"; exit 0; fi' \
    'printf "%s\\n" "$*"' > "${scratch}/bin/docker"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s|%s\\n" "$PWD" "$*"' > "${scratch}/bin/local-probe"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s|%s\\n" "$PWD" "$*"' > "${scratch}/bin/zig"
chmod 755 "${scratch}/bin/docker" "${scratch}/bin/local-probe" "${scratch}/bin/zig"

host_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" /bin/true)"
[[ "${host_exec}" == *"--workdir /workspaces/glowcap abc123 /bin/true"* ]]

build_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" zig build test)"
[[ "${build_exec}" == *"/workspaces/glowcap/.devcontainer/bin/build-lease zig build --test-timeout 30s test"* ]]
[[ "${build_exec}" == *"exec -i --user"* ]]
explicit_timeout_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" zig build test --test-timeout 7s)"
[[ "${explicit_timeout_exec}" == *"build-lease zig build test --test-timeout 7s"* ]]
[[ "${explicit_timeout_exec}" != *"--test-timeout 30s"* ]]
service_status=0
if service_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" zig build docs-serve 2>&1)"; then
    echo "test/build-front: glowcap-dev accepted a host-side service without a terminal" >&2
    exit 1
else
    service_status=$?
fi
[[ ${service_status} -eq 2 ]]
[[ "${service_exec}" == *"service build requires a terminal"* ]]

local_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEVCONTAINER_DIR="${container_dir}" "${front}" local-probe one two)"
[[ "${local_exec}" == "${repo_root}|one two" ]]
local_build_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEVCONTAINER_DIR="${container_dir}" GLOWCAP_BUILD_LEASE_FILE="${scratch}/local-build.lock" "${front}" zig build test)"
[[ "${local_build_exec}" == "${repo_root}|build --test-timeout 30s test" ]]
forced_container_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEVCONTAINER_DIR="${container_dir}" GLOWCAP_DEV_CONTAINER=test-container "${front}" /bin/true)"
[[ "${forced_container_exec}" == *"--workdir /workspaces/glowcap abc123 /bin/true"* ]]

if [[ $(uname -s) == Linux ]]; then
    auto_container_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" --auto zig build rooms-build)"
    [[ "${auto_container_exec}" == *"abc123 /workspaces/glowcap/.devcontainer/bin/build-lease zig build --test-timeout 30s rooms-build"* ]]
fi
explicit_local="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" --local local-probe local)"
[[ "${explicit_local}" == "${repo_root}|local" ]]

# Emulate host OS selection, not execution of a foreign binary. Even with a
# Linux container running, macOS must build locally. An automatically found
# foreign architecture also falls back locally; an explicit selection refuses.
real_uname=$(command -v uname)
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ $1 == -s && -n ${FAKE_HOST_OS:-} ]]; then printf "%s\\n" "$FAKE_HOST_OS"; else "$REAL_UNAME" "$@"; fi' >"${scratch}/bin/uname"
chmod +x "${scratch}/bin/uname"
for tool in cargo deno wasm-bindgen python3; do
    ln -s local-probe "${scratch}/bin/${tool}"
done
mac_local=$(cd / && PATH="${scratch}/bin:${PATH}" REAL_UNAME="${real_uname}" FAKE_HOST_OS=Darwin \
    GLOWCAP_DEVCONTAINER_DIR='' GLOWCAP_DEV_CONTAINER='' "${front}" --auto local-probe mac)
[[ ${mac_local} == "${repo_root}|mac" ]]
foreign_local=$(cd / && PATH="${scratch}/bin:${PATH}" REAL_UNAME="${real_uname}" FAKE_HOST_OS=Linux FAKE_CONTAINER_ARCH=foreign \
    GLOWCAP_DEVCONTAINER_DIR='' GLOWCAP_DEV_CONTAINER='' "${front}" --auto local-probe foreign)
[[ ${foreign_local} == "${repo_root}|foreign" ]]
foreign_status=0
PATH="${scratch}/bin:${PATH}" REAL_UNAME="${real_uname}" FAKE_HOST_OS=Linux FAKE_CONTAINER_ARCH=foreign \
    GLOWCAP_DEVCONTAINER_DIR='' GLOWCAP_DEV_CONTAINER=test-container "${front}" --auto local-probe refused \
    >"${scratch}/foreign-log" 2>&1 || foreign_status=$?
[[ ${foreign_status} -eq 1 ]]
grep -F 'selected container architecture foreign' "${scratch}/foreign-log" >/dev/null

# Bootstrap once, then operate the complete product without build tools. A
# failed bootstrap cannot dispatch a partial product or consume protocol stdin.
launcher_root="${scratch}/checkout with spaces"
mkdir -p "${launcher_root}/.devcontainer/bin" "${launcher_root}/zig-out/product/bin" \
    "${launcher_root}/zig-out/product/share/glowcap"
cp "${repo_root}/glowcap" "${launcher_root}/glowcap"
ln -s "${launcher_root}/glowcap" "${scratch}/launch"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
    'echo "builder:$*"' \
    'echo "builder diagnostic" >&2' \
    'if [[ ${FAKE_BUILD_FAIL:-0} == 1 ]]; then exit 37; fi' \
    'if IFS= read -r stolen; then echo "stole stdin: $stolen"; fi' \
    'cp "$LAUNCHER_PRODUCT" "$LAUNCHER_ROOT/zig-out/product/bin/glowcap"' \
    'chmod +x "$LAUNCHER_ROOT/zig-out/product/bin/glowcap"' \
    ': >"$LAUNCHER_ROOT/zig-out/product/share/glowcap/installation.manifest"' >"${launcher_root}/.devcontainer/bin/run.sh"
chmod +x "${launcher_root}/.devcontainer/bin/run.sh"
launcher_product="${scratch}/product"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' '[[ ${GLOWCAP_CHECKOUT_ROOT} == "$LAUNCHER_ROOT" ]] || exit 91' \
    'echo "product diagnostic" >&2' 'printf "first:%s\\n" "$*"' >"${launcher_product}"
chmod +x "${launcher_product}"
launcher_output=$(cd / && LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" "${scratch}/launch" version 2>"${scratch}/launcher-log")
[[ ${launcher_output} == first:version ]]
grep -Fx 'builder:--auto zig build rooms-build -Doptimize=ReleaseSafe -Dcpu=baseline' "${scratch}/launcher-log" >/dev/null
grep -Fx 'builder diagnostic' "${scratch}/launcher-log" >/dev/null
grep -Fx 'product diagnostic' "${scratch}/launcher-log" >/dev/null
launcher_log=$(<"${scratch}/launcher-log")
[[ ${launcher_log} == *'command has not started yet'*'builder:'*'builder diagnostic'*'checkout product ready; starting command'*'product diagnostic'* ]]
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ -n ${GLOWCAP_BIN:-} && -n ${GLOWCAP_CHECKOUT_ROOT:-} ]]; then exit 92; fi' \
    'IFS= read -r input; printf "second:%s:%s\\n" "$*" "$input"' >"${launcher_product}"
# Changing source and making the builder unavailable cannot block a command or
# silently select a different product. Replies, ticks and listeners share this.
for command in 'apps rooms session reply' 'apps rooms session tick' 'apps rooms session listen'; do
    launcher_output=$(LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" FAKE_BUILD_FAIL=1 \
        "${scratch}/launch" "$command" 2>"${scratch}/launcher-log")
    [[ ${launcher_output} == "first:$command" ]]
    if grep -F 'builder' "${scratch}/launcher-log" >/dev/null; then
        echo "test/build-front: operating the prepared product invoked its builder" >&2
        exit 1
    fi
done
# Simulate an explicit product build, then check transparent stdin forwarding.
cp "${launcher_product}" "${launcher_root}/zig-out/product/bin/glowcap"
launcher_output=$(printf 'retained input\n' | LAUNCHER_ROOT="${launcher_root}" FAKE_BUILD_FAIL=1 "${scratch}/launch" 'two words' 2>"${scratch}/launcher-log")
[[ ${launcher_output} == 'second:two words:retained input' ]]
rm "${launcher_root}/zig-out/product/share/glowcap/installation.manifest"
launcher_status=0
LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" FAKE_BUILD_FAIL=1 \
    "${scratch}/launch" version >"${scratch}/launcher-output" 2>"${scratch}/launcher-log" || launcher_status=$?
[[ ${launcher_status} -eq 37 && ! -s ${scratch}/launcher-output ]]
grep -F 'checkout preparation failed; command was not started' "${scratch}/launcher-log" >/dev/null
if grep -F 'checkout product ready' "${scratch}/launcher-log" >/dev/null; then
    echo "test/build-front: launcher reported readiness after a failed build" >&2
    exit 1
fi
launcher_output=$(printf 'existing\n' | FAKE_BUILD_FAIL=1 GLOWCAP_CHECKOUT_ROOT=/unrelated GLOWCAP_BIN="${launcher_product}" "${scratch}/launch" version)
[[ ${launcher_output} == 'second:version:existing' ]]

lease_file="${scratch}/build.lock"
GLOWCAP_BUILD_LEASE_FILE="${lease_file}" "${lease_runner}" /bin/true
GLOWCAP_BUILD_LEASE_FILE="${lease_file}" "${lease_runner}" \
    python3 -c 'import time; time.sleep(30)' &
lease_owner_pid=$!
for _ in {1..100}; do
    if grep -F "pid: ${lease_owner_pid}" "${lease_file}" >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "${lease_owner_pid}" 2>/dev/null; then
        echo "test/build-front: build lease owner exited during setup" >&2
        exit 1
    fi
    sleep 0.01
done
grep -F "pid: ${lease_owner_pid}" "${lease_file}" >/dev/null
lease_output="${scratch}/lease-output"
if GLOWCAP_BUILD_LEASE_FILE="${lease_file}" "${lease_runner}" /bin/true >"${lease_output}" 2>&1; then
    echo "test/build-front: build lease ignored an active owner" >&2
    exit 1
else
    lease_status=$?
fi
[[ ${lease_status} -eq 75 ]]
grep -F "another build owns this worktree" "${lease_output}" >/dev/null
grep -F "pid: ${lease_owner_pid}" "${lease_output}" >/dev/null
grep -F "command: python3 -c 'import time; time.sleep(30)'" "${lease_output}" >/dev/null
grep -F "inspect that build, then retry" "${lease_output}" >/dev/null

if GLOWCAP_BUILD_LEASE_FILE="${lease_file}" GLOWCAP_BUILD_LEASE_TIMEOUT=0.05 \
    "${lease_runner}" /bin/true >"${lease_output}" 2>&1; then
    echo "test/build-front: timed build lease wait ignored an active owner" >&2
    exit 1
else
    lease_status=$?
fi
[[ ${lease_status} -eq 75 ]]
grep -F "waiting up to 0.05s" "${lease_output}" >/dev/null
grep -F "still owns the lease after 0.05s" "${lease_output}" >/dev/null

kill "${lease_owner_pid}"
wait "${lease_owner_pid}" 2>/dev/null || true
lease_owner_pid=""
GLOWCAP_BUILD_LEASE_FILE="${lease_file}" "${lease_runner}" /bin/true

lease_release="${scratch}/lease-release"
GLOWCAP_BUILD_LEASE_FILE="${lease_file}" "${lease_runner}" \
    python3 -c $'import os, sys, time\npath = sys.argv[1]\nwhile not os.path.exists(path):\n    time.sleep(0.01)' "${lease_release}" &
lease_owner_pid=$!
for _ in {1..100}; do
    grep -F "pid: ${lease_owner_pid}" "${lease_file}" >/dev/null 2>&1 && break
    sleep 0.01
done
grep -F "pid: ${lease_owner_pid}" "${lease_file}" >/dev/null
GLOWCAP_BUILD_LEASE_FILE="${lease_file}" GLOWCAP_BUILD_LEASE_TIMEOUT=5 \
    "${lease_runner}" /bin/true >"${lease_output}" 2>&1 &
lease_waiter_pid=$!
for _ in {1..100}; do
    grep -F "waiting up to 5s" "${lease_output}" >/dev/null 2>&1 && break
    sleep 0.01
done
grep -F "waiting up to 5s" "${lease_output}" >/dev/null
: >"${lease_release}"
wait "${lease_owner_pid}"
lease_owner_pid=""
lease_status=0
wait "${lease_waiter_pid}" || lease_status=$?
lease_waiter_pid=""
[[ ${lease_status} -eq 0 ]]
grep -F "waiting up to 5s" "${lease_output}" >/dev/null

lease_status=0
if GLOWCAP_BUILD_LEASE_FILE="${lease_file}" "${lease_runner}" >"${lease_output}" 2>&1; then
    echo "test/build-front: build lease accepted no command" >&2
    exit 1
else
    lease_status=$?
fi
[[ ${lease_status} -eq 2 ]]
grep -F "command required" "${lease_output}" >/dev/null

lease_status=0
if GLOWCAP_BUILD_LEASE_FILE="${lease_file}" GLOWCAP_BUILD_LEASE_TIMEOUT=forever \
    "${lease_runner}" /bin/true >"${lease_output}" 2>&1; then
    echo "test/build-front: build lease accepted an invalid wait timeout" >&2
    exit 1
else
    lease_status=$?
fi
[[ ${lease_status} -eq 2 ]]
grep -F "must be a non-negative number" "${lease_output}" >/dev/null

lease_status=0
if GLOWCAP_BUILD_LEASE_FILE="${lease_file}" "${lease_runner}" glowcap-command-does-not-exist >"${lease_output}" 2>&1; then
    echo "test/build-front: build lease accepted a missing command" >&2
    exit 1
else
    lease_status=$?
fi
[[ ${lease_status} -eq 127 ]]
grep -F "command not found" "${lease_output}" >/dev/null

lease_noexec="${scratch}/lease-noexec"
printf 'not executable\n' >"${lease_noexec}"
chmod 644 "${lease_noexec}"
lease_status=0
if GLOWCAP_BUILD_LEASE_FILE="${lease_file}" "${lease_runner}" "${lease_noexec}" >"${lease_output}" 2>&1; then
    echo "test/build-front: build lease executed a non-executable command" >&2
    exit 1
else
    lease_status=$?
fi
[[ ${lease_status} -eq 126 ]]
grep -F "command is not executable" "${lease_output}" >/dev/null
