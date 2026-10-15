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
# The lease steps below expect a contender to exit at once, so an inherited
# wait from the build that runs this test must not reach them.
unset CARGO_BUILD_BUILD_DIR CARGO_BUILD_JOBS RUSTC GLOWCAP_BUILD_LEASE_TIMEOUT GLOWCAP_BUILD_LEASE_FILE

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
    'if [[ "$*" == *"kill -TERM"* && -n "${FAKE_DOCKER_LOG:-}" ]]; then printf "%s\\n" "$*" >> "${FAKE_DOCKER_LOG}"; kill "$(cat "${FAKE_DOCKER_LOG}.client")"; exit 0; fi' \
    'if [[ "$*" == *setsid* && -n "${FAKE_DOCKER_HANG:-}" ]]; then echo "$$" > "${FAKE_DOCKER_LOG}.client"; exec sleep 30; fi' \
    'if [[ "$*" == *setsid* && -n "${FAKE_DOCKER_READY:-}" ]]; then touch "$FAKE_DOCKER_READY"; for _ in {1..200}; do [[ -f "$FAKE_DOCKER_READY.release" ]] && break; sleep 0.01; done; [[ -f "$FAKE_DOCKER_READY.release" ]] || exit 37; fi' \
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
[[ "${host_exec}" == *"--workdir /workspaces/glowcap abc123 setsid --wait sh -c "* ]]
[[ "${host_exec}" == *" /bin/true" ]]
[[ "${host_exec}" == *"--env CARGO_BUILD_BUILD_DIR=/home/vscode/.cache/glowcap-dev-zig-work/cargo/{workspace-path-hash}"* ]]
[[ "${host_exec}" == *"--env CARGO_BUILD_JOBS=4"* ]]
inherited_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container CARGO_BUILD_JOBS=7 "${front}" /bin/true)"
[[ "${inherited_exec}" == *"--env CARGO_BUILD_JOBS=7"* && "${inherited_exec}" != *"--env CARGO_BUILD_JOBS=4"* ]]

# The native linker finds the active compiler's bundled LLD independently of
# cwd, preserves argument boundaries, and propagates compiler refusal.
linker_lib="${scratch}/rust toolchain/lib/rustlib/native/lib"
linker_bin="$(dirname "${linker_lib}")/bin/gcc-ld"
mkdir -p "${linker_lib}" "${linker_bin}"
touch "${linker_bin}/ld.lld"
chmod 755 "${linker_bin}/ld.lld"
# shellcheck disable=SC2016 # Expanded only by the isolated fake tools.
printf '%s\n' '#!/usr/bin/env bash' '[[ "$*" == "--print target-libdir" ]]' 'printf "%s\n" "$LINKER_TEST_LIB_DIR"' > "${scratch}/bin/rustc"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$@"' 'exit "${LINKER_TEST_STATUS:-0}"' > "${scratch}/bin/cc"
chmod 755 "${scratch}/bin/rustc" "${scratch}/bin/cc"
linker_args="$(cd / && PATH="${scratch}/bin:${PATH}" LINKER_TEST_LIB_DIR="${linker_lib}" bash "${container_dir}/bin/rust-linker.sh" 'one object.o')"
[[ "${linker_args}" == "-B${linker_bin}"$'\n-fuse-ld=lld\none object.o' ]]
linker_status=0
PATH="${scratch}/bin:${PATH}" LINKER_TEST_LIB_DIR="${linker_lib}" LINKER_TEST_STATUS=17 \
    bash "${container_dir}/bin/rust-linker.sh" >"${scratch}/linker-log" 2>&1 || linker_status=$?
[[ ${linker_status} -eq 17 ]]
rm "${linker_bin}/ld.lld"
linker_status=0
PATH="${scratch}/bin:${PATH}" LINKER_TEST_LIB_DIR="${linker_lib}" \
    bash "${container_dir}/bin/rust-linker.sh" >"${scratch}/linker-log" 2>&1 || linker_status=$?
[[ ${linker_status} -eq 1 ]]
grep -F 'no bundled Linux LLD' "${scratch}/linker-log" >/dev/null

# The front's wait must report its child status even if the checkout front is
# edited while the child runs. Mutate only this isolated copy in place.
mutable_root="${scratch}/mutable"
mkdir -p "${mutable_root}/.devcontainer/bin"
ln -s "${container_dir}/lib" "${mutable_root}/.devcontainer/lib"
cp "${container_dir}/pins.sh" "${mutable_root}/.devcontainer/pins.sh"
mutable_front="${mutable_root}/.devcontainer/bin/run.sh"
cp "${container_dir}/bin/run.sh" "${mutable_front}"
ready="${scratch}/front-ready"
PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container FAKE_DOCKER_READY="${ready}" \
    bash "${mutable_front}" /bin/true >"${scratch}/mutable-log" 2>&1 &
mutable_pid=$!
for _ in {1..100}; do
    [[ -f ${ready} ]] && break
    sleep 0.01
done
[[ -f ${ready} ]]
{ for _ in {1..200}; do printf '# inserted source line\n'; done; cat "${mutable_front}"; } >"${scratch}/edited-front"
cat "${scratch}/edited-front" >"${mutable_front}"
: >"${ready}.release"
mutable_status=0
wait "${mutable_pid}" || mutable_status=$?
if [[ ${mutable_status} -ne 0 ]]; then
    cat "${scratch}/mutable-log" >&2
    echo "test/build-front: editing the front changed its child's exit status (${mutable_status})" >&2
    exit 1
fi

# Stopping a front with no terminal signals the command's container process
# group instead of leaving it running.
docker_log="${scratch}/docker-log"
(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container FAKE_DOCKER_HANG=1 FAKE_DOCKER_LOG="${docker_log}" exec "${front}" /bin/true </dev/null) &
front_pid=$!
sleep 1
kill -TERM "${front_pid}"
front_status=0
wait "${front_pid}" || front_status=$?
[[ ${front_status} -eq 143 ]]
grep -F "kill -TERM" "${docker_log}" >/dev/null

build_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" zig build test)"
[[ "${build_exec}" == *"/workspaces/glowcap/.devcontainer/bin/build-lease zig build --cache-poison --test-timeout 30s test"* ]]
[[ "${build_exec}" == *"exec -i "* && "${build_exec}" == *"--user vscode"* ]]
waiting_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container GLOWCAP_BUILD_LEASE_TIMEOUT=600 "${front}" zig build test)"
[[ "${waiting_exec}" == *"exec -i --env GLOWCAP_BUILD_LEASE_TIMEOUT=600 "* ]]
explicit_timeout_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" zig build test --test-timeout 7s)"
[[ "${explicit_timeout_exec}" == *"build-lease zig build --cache-poison test --test-timeout 7s"* ]]
[[ "${explicit_timeout_exec}" != *"--test-timeout 30s"* ]]
override_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" --env CARGO_BUILD_JOBS=1 zig build test)"
[[ "${override_exec}" == *"--env CARGO_BUILD_JOBS=1"* ]]
[[ "${override_exec}" != *"--env CARGO_BUILD_JOBS=4"* ]]
[[ "${override_exec}" == *"build-lease zig build --cache-poison --test-timeout 30s test"* ]]
# shellcheck disable=SC2016 # Both the literal value and the child expansion are intentional.
override_local="$(cd / && PATH="${scratch}/bin:${PATH}" "${front}" --local --env 'GLOWCAP_TEST_VALUE=two words=$literal' bash -c 'printf "%s" "$GLOWCAP_TEST_VALUE"')"
# shellcheck disable=SC2016 # Compare the exact literal delivered to the child.
[[ "${override_local}" == 'two words=$literal' ]]
for invalid in 'missing-assignment' '1INVALID=value' '=value'; do
    override_status=0
    "${front}" --env "${invalid}" /bin/true >"${scratch}/override-log" 2>&1 || override_status=$?
    [[ ${override_status} -eq 2 ]]
done
override_status=0
"${front}" --env >"${scratch}/override-log" 2>&1 || override_status=$?
[[ ${override_status} -eq 2 ]]
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
[[ "${local_build_exec}" == "${repo_root}|build --cache-poison --test-timeout 30s test" ]]
forced_container_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEVCONTAINER_DIR="${container_dir}" GLOWCAP_DEV_CONTAINER=test-container "${front}" /bin/true)"
[[ "${forced_container_exec}" == *"--workdir /workspaces/glowcap abc123 setsid --wait sh -c "*" /bin/true" ]]

if [[ $(uname -s) == Linux ]]; then
    auto_container_exec="$(cd / && PATH="${scratch}/bin:${PATH}" GLOWCAP_DEV_CONTAINER=test-container "${front}" --auto zig build rooms-build)"
    [[ "${auto_container_exec}" == *"abc123 setsid --wait sh -c "*" /workspaces/glowcap/.devcontainer/bin/build-lease zig build --cache-poison --test-timeout 30s rooms-build"* ]]
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
    ': >"$LAUNCHER_ROOT/zig-out/product/share/glowcap/installation.manifest"' \
    'printf "{\"checkout_preparation\":true}\n" >"$LAUNCHER_ROOT/zig-out/product/share/glowcap/release.json"' >"${launcher_root}/.devcontainer/bin/run.sh"
chmod +x "${launcher_root}/.devcontainer/bin/run.sh"
launcher_product="${scratch}/product"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' '[[ ${GLOWCAP_CHECKOUT_ROOT} == "$LAUNCHER_ROOT" ]] || exit 91' \
    'echo "product diagnostic" >&2' 'echo "prepared:${GLOWCAP_CHECKOUT_PREPARED:-unset}" >&2' \
    'printf "first:%s\\n" "$*"' >"${launcher_product}"
chmod +x "${launcher_product}"
launcher_output=$(cd / && LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" "${scratch}/launch" version 2>"${scratch}/launcher-log")
[[ ${launcher_output} == first:version ]]
grep -Fx 'builder:--auto zig build rooms-release' "${scratch}/launcher-log" >/dev/null
grep -Fx 'builder diagnostic' "${scratch}/launcher-log" >/dev/null
grep -Fx 'product diagnostic' "${scratch}/launcher-log" >/dev/null
launcher_log=$(<"${scratch}/launcher-log")
[[ ${launcher_log} == *'command has not started yet'*'builder:'*'builder diagnostic'*'checkout product ready; starting command'*'product diagnostic'* ]]
# A validated deployment requests preparation even when its product exists.
# The CLI process proof owns which commands request it. This front owns the
# build, refusal, and transparent forwarding of the original command.
for verb in up reset; do
    launcher_output=$(cd / && LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" \
        GLOWCAP_PREPARE_CHECKOUT="${launcher_root}" \
        "${scratch}/launch" apps rooms deployment "$verb" 2>"${scratch}/launcher-log")
    [[ ${launcher_output} == "first:apps rooms deployment $verb" ]]
    grep -Fx 'builder:--auto zig build rooms-release' "${scratch}/launcher-log" >/dev/null
    grep -Fx "prepared:${launcher_root}" "${scratch}/launcher-log" >/dev/null
    launcher_status=0
    LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" FAKE_BUILD_FAIL=1 \
        GLOWCAP_PREPARE_CHECKOUT="${launcher_root}" \
        "${scratch}/launch" apps rooms deployment "$verb" >"${scratch}/launcher-output" 2>"${scratch}/launcher-log" || launcher_status=$?
    [[ ${launcher_status} -eq 37 && ! -s ${scratch}/launcher-output ]]
done
# A bare `! grep` is exempt from errexit and would never fail this script.
refuse_builder() {
    if grep -F 'builder:' "${scratch}/launcher-log" >/dev/null; then
        echo "test/build-front: launcher invoked its builder for: $*" >&2
        exit 1
    fi
}
# The CLI owns explicit sources, syntax, and help. Read-only and restart paths
# must keep working when the compiler or development container is unavailable.
for verb in up reset; do
    for source in '--image=example:test' '--build=/prepared product' --help -h; do
        launcher_output=$(LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" FAKE_BUILD_FAIL=1 \
            PATH="${scratch}/bin:${PATH}" REAL_UNAME="${real_uname}" FAKE_HOST_OS=Linux \
            "${scratch}/launch" apps rooms deployment "$verb" "$source" 2>"${scratch}/launcher-log")
        [[ ${launcher_output} == "first:apps rooms deployment $verb $source" ]]
        refuse_builder "${launcher_output}"
    done
    for source in --image --build; do
        launcher_output=$(LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" FAKE_BUILD_FAIL=1 \
            "${scratch}/launch" apps rooms deployment "$verb" "$source" 'two words' 2>"${scratch}/launcher-log")
        [[ ${launcher_output} == "first:apps rooms deployment $verb $source two words" ]]
        refuse_builder "${launcher_output}"
    done
done
for verb in doctor status logs trace down restart; do
    launcher_output=$(LAUNCHER_ROOT="${launcher_root}" FAKE_BUILD_FAIL=1 \
        "${scratch}/launch" apps rooms deployment "$verb" 2>"${scratch}/launcher-log")
    [[ ${launcher_output} == "first:apps rooms deployment $verb" ]]
    refuse_builder "${launcher_output}"
done
# A macOS checkout operates its host product and selects a Linux image source
# through the CLI. It must not replace its executable with a Linux build.
launcher_output=$(LAUNCHER_ROOT="${launcher_root}" FAKE_BUILD_FAIL=1 \
    PATH="${scratch}/bin:${PATH}" REAL_UNAME="${real_uname}" FAKE_HOST_OS=Darwin \
    "${scratch}/launch" apps rooms deployment up 2>"${scratch}/launcher-log")
[[ ${launcher_output} == 'first:apps rooms deployment up' ]]
refuse_builder "${launcher_output}"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ -n ${GLOWCAP_BIN:-} && -n ${GLOWCAP_CHECKOUT_ROOT:-} ]]; then exit 92; fi' \
    'IFS= read -r input; printf "second:%s:%s\\n" "$*" "$input"' >"${launcher_product}"
# Changing source and making the builder unavailable cannot block a command or
# silently select a different product. Replies, ticks and listeners share this.
for command in 'apps rooms session reply' 'apps rooms session tick' 'apps rooms session listen'; do
    launcher_output=$(LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" FAKE_BUILD_FAIL=1 \
        GLOWCAP_CHECKOUT_PREPARED="${launcher_root}" \
        "${scratch}/launch" "$command" 2>"${scratch}/launcher-log")
    [[ ${launcher_output} == "first:$command" ]]
    grep -Fx 'prepared:unset' "${scratch}/launcher-log" >/dev/null
    if grep -F 'builder' "${scratch}/launcher-log" >/dev/null; then
        echo "test/build-front: operating the prepared product invoked its builder" >&2
        exit 1
    fi
done
# Simulate an explicit product build, then check transparent stdin forwarding.
cp "${launcher_product}" "${launcher_root}/zig-out/product/bin/glowcap"
launcher_output=$(printf 'retained input\n' | LAUNCHER_ROOT="${launcher_root}" FAKE_BUILD_FAIL=1 "${scratch}/launch" 'two words' 2>"${scratch}/launcher-log")
[[ ${launcher_output} == 'second:two words:retained input' ]]
launcher_output=$(printf 'retained input\n' | LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" \
    GLOWCAP_PREPARE_CHECKOUT="${launcher_root}" \
    "${scratch}/launch" apps rooms deployment reset all 2>"${scratch}/launcher-log")
[[ ${launcher_output} == 'second:apps rooms deployment reset all:retained input' ]]
# A product that lacks the preparation contract is incomplete, even if its
# executable and inventory exist. It must not silently deploy an older CLI.
printf '{}\n' >"${launcher_root}/zig-out/product/share/glowcap/release.json"
launcher_status=0
LAUNCHER_ROOT="${launcher_root}" LAUNCHER_PRODUCT="${launcher_product}" FAKE_BUILD_FAIL=1 \
    "${scratch}/launch" version >"${scratch}/launcher-output" 2>"${scratch}/launcher-log" || launcher_status=$?
[[ ${launcher_status} -eq 37 && ! -s ${scratch}/launcher-output ]]
printf '{"checkout_preparation":true}\n' >"${launcher_root}/zig-out/product/share/glowcap/release.json"
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
launcher_output=$(printf 'existing\n' | FAKE_BUILD_FAIL=1 GLOWCAP_CHECKOUT_ROOT=/unrelated GLOWCAP_BIN="${launcher_product}" \
    GLOWCAP_PREPARE_CHECKOUT="${launcher_root}" \
    "${scratch}/launch" apps rooms deployment up)
[[ ${launcher_output} == 'second:apps rooms deployment up:existing' ]]

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
