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
[[ "${build_exec}" == *"/workspaces/glowcap/.agents/skills/work/bin/glowcap-build-lease zig build --test-timeout 30s test"* ]]
explicit_timeout_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" zig build test --test-timeout 7s)"
[[ "${explicit_timeout_exec}" == *"glowcap-build-lease zig build test --test-timeout 7s"* ]]
[[ "${explicit_timeout_exec}" != *"--test-timeout 30s"* ]]
service_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" zig build docs-serve)"
[[ "${service_exec}" == *"zig build --test-timeout 30s docs-serve"* ]]
[[ "${service_exec}" != *"glowcap-build-lease"* ]]

local_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEVCONTAINER_DIR="${container_dir}" "${front}" local-probe one two)"
[[ "${local_exec}" == "${repo_root}|one two" ]]
local_build_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEVCONTAINER_DIR="${container_dir}" GLOWCAP_BUILD_LEASE_FILE="${scratch}/local-build.lock" "${front}" zig build test)"
[[ "${local_build_exec}" == "${repo_root}|build --test-timeout 30s test" ]]
forced_container_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEVCONTAINER_DIR="${container_dir}" GLOWCAP_DEV_CONTAINER=test-container "${front}" /bin/true)"
[[ "${forced_container_exec}" == *"--workdir /workspaces/glowcap abc123 /bin/true"* ]]

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
