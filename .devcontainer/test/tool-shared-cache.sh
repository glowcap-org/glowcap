#!/usr/bin/env bash
# Cross-container exclusion proof for the managed-tool lifecycle, run on a
# Docker host: two disposable containers from one candidate image, separate
# PID namespaces, one fresh Docker volume standing in for the shared cache
# bind's filesystem. Stub drivers and --network none keep vendor downloads
# and logins out; the lifecycle, dispatcher, and front under test are the
# checkout's own.
#
#   tool-shared-cache.sh <candidate-image-id>
#
# It proves, on one shared filesystem with two independent containers: one
# install under contention; competing updates cannot regress the selection;
# an abruptly killed lock holder releases the lock and leaves the working
# selection; a warm reader's files survive another container's update.
# Cleanup removes only the named containers, the named volume, and the
# fixture directory this run created.
#
# This is an integration proof, not part of `infrastructure-check`: it needs
# a Docker host. Run it through the environment front with --local and an
# explicit candidate image, e.g.
#   .agents/skills/work/bin/glowcap-dev --local bash \
#     .devcontainer/test/tool-shared-cache.sh <image-id>

set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "${dir}/.." && pwd)"

image="${1:-}"
if [[ -z "${image}" ]]; then
    echo "usage: tool-shared-cache.sh <candidate-image-id>" >&2
    exit 64
fi
if ! command -v docker >/dev/null 2>&1; then
    echo "tool-shared-cache: docker is not on PATH; run this on a Docker host" >&2
    exit 1
fi

failures=0
checks=0
fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    echo "tool-shared-cache: FAIL: $1" >&2
}
pass() {
    checks=$((checks + 1))
}

fixture="/tmp/tool-lockproof-fixture-$$"
volume="glowcap-tool-lockproof-$$"
containers=()
cleanup() {
    for c in "${containers[@]:-}"; do
        docker rm -f "${c}" >/dev/null 2>&1 || true
    done
    docker volume rm "${volume}" >/dev/null 2>&1 || true
    rm -rf "${fixture}" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Fixture: the real tools runtime, plus appended stub rows, a stub seed, and
# a stub release channel whose latest comes from the environment. The stub
# download waits for a release file in the container, then writes a
# self-answering binary.
# ---------------------------------------------------------------------------
mkdir -p "${fixture}"
cp -R "${dir}/tools" "${fixture}/tools"
cp "${dir}/pins.sh" "${fixture}/pins.sh"
cp "${dir}/lib/update-pins-deps.sh" "${fixture}/update-pins-deps.sh"
cat >> "${fixture}/pins.sh" <<'PINS'
STUB_VERSION="1.2.0"
PINS
cat >> "${fixture}/tools/lib/registry.sh" <<'REG'

# Lock-proof stub row.
glowcap_tools_registry_rows() {
    printf '%s\n' "stub|stub|STUB_VERSION|stub"
}
glowcap_pins_query_version() {
    printf '%s\n' "${STUB_LATEST_STUB:-}"
}
REG
cat >> "${fixture}/update-pins-deps.sh" <<'QRY'

# Stub release channel for the lock proof; validation stays real.
glowcap_pins_query_version() {
    printf '%s\n' "${STUB_LATEST_STUB:-}"
}
QRY
cat > "${fixture}/tools/lib/stub.sh" <<'DRV'
glowcap_tools_stub_download() {
    local version="$1" install_dir="$2" i=0
    mkdir -p "${install_dir}" || return 1
    # The first scenario holds this installer inside its lock: while the gate
    # file exists, wait. Later scenarios run ungated.
    if [[ -e /tmp/lockproof-gate ]]; then
        printf 'stub download gated for release %s\n' "${version}" >&2
        while [[ -e /tmp/lockproof-gate && "${i}" -lt 120 ]]; do
            sleep 1
            i=$((i + 1))
        done
    fi
    printf '#!/bin/sh\nprintf "stub-%s $*\\n"\n' "${version}" > "${install_dir}/bin" || return 1
    chmod +x "${install_dir}/bin" || return 1
    GLOWCAP_TOOLS_SOURCE_URL="stub://${version}"
    GLOWCAP_TOOLS_VERIFICATION="none"
    GLOWCAP_TOOLS_EXPECTED_SHA=""
    GLOWCAP_TOOLS_OBSERVED_SHA=""
}
glowcap_tools_stub_verify() {
    local out
    out="$("$1/bin" --version)" || return 1
    [[ "${out}" == "stub-$2 --version" ]]
}
glowcap_tools_stub_exec_path() { printf '%s\n' "$1/bin"; }
glowcap_tools_stub_intercept() { printf 'pass\n'; }
DRV

docker volume create "${volume}" >/dev/null || {
    echo "tool-shared-cache: cannot create the proof volume" >&2
    exit 1
}

run_container() {
    local name="glowcap-tool-lockproof-$1-$$"
    containers+=("${name}")
    docker run --rm -d --name "${name}" \
        --network none \
        --user vscode \
        -v "${repo_root}/.devcontainer/lib:/workspaces/glowcap/.devcontainer/lib:ro" \
        -v "${repo_root}/.devcontainer/bin/tools.sh:/workspaces/glowcap/.devcontainer/bin/tools.sh:ro" \
        -v "${fixture}/pins.sh:/workspaces/glowcap/.devcontainer/pins.sh:ro" \
        -v "${repo_root}/.devcontainer/checksums.sh:/workspaces/glowcap/.devcontainer/checksums.sh:ro" \
        -v "${fixture}/update-pins-deps.sh:/workspaces/glowcap/.devcontainer/lib/update-pins-deps.sh:ro" \
        -v "${fixture}/tools:/workspaces/glowcap/.devcontainer/tools:ro" \
        -v "${volume}:/home/vscode/.cache/glowcap" \
        "${image}" sleep infinity >/dev/null || {
        echo "tool-shared-cache: cannot start ${name} from ${image}" >&2
        exit 1
    }
    printf '%s\n' "${name}"
}

tools_in() {
    local container="$1"
    shift
    docker exec -u vscode "${container}" \
        bash /workspaces/glowcap/.devcontainer/bin/tools.sh "$@"
}

selection_version() {
    docker exec -u vscode "$1" bash -c \
        'grep -m1 "^version=" /home/vscode/.cache/glowcap/installed/linux-$(uname -m)/stub/installs/$(readlink /home/vscode/.cache/glowcap/installed/linux-$(uname -m)/stub/current | xargs basename)/receipt' \
        2>/dev/null | cut -d= -f2
}

a="$(run_container a)"
b="$(run_container b)"
docker exec "${a}" touch /tmp/lockproof-gate >/dev/null 2>&1 || true
echo "tool-shared-cache: containers ${a} ${b}"

# ---------------------------------------------------------------------------
# 1. One install under contention: A holds the lock inside its download; B
#    reports contention and exits 75; the release lets A publish; both
#    containers see exactly one complete install and one valid selection.
# ---------------------------------------------------------------------------
tools_in "${a}" ensure stub >/dev/null 2>&1 &
ensure_pid=$!
sleep 2
out="$(docker exec -u vscode -e GLOWCAP_TOOLS_LOCK_WAIT=2 "${b}" \
    bash /workspaces/glowcap/.devcontainer/bin/tools.sh ensure stub 2>&1)"
if [[ "${out}" == *"holds the lock"* ]]; then
    pass
else
    fail "contender did not report contention: ${out}"
fi
docker exec "${a}" rm -f /tmp/lockproof-gate >/dev/null 2>&1 || true
wait "${ensure_pid}" 2>/dev/null
ensure_rc=$?
if [[ "${ensure_rc}" -eq 0 ]]; then
    pass
else
    fail "holder's ensure failed: ${ensure_rc}"
fi
install_count="$(docker exec "${b}" bash -c \
    'ls /home/vscode/.cache/glowcap/installed/linux-$(uname -m)/stub/installs 2>/dev/null | wc -l')"
if [[ "${install_count}" -eq 1 ]]; then
    pass
else
    fail "expected exactly one install after contention, saw ${install_count}"
fi
# Scenario 1's install is the seed (ensure installs the seed, not latest).
if [[ "$(selection_version "${b}")" == "1.2.0" ]]; then
    pass
else
    fail "container B sees selection '$(selection_version "${b}")', expected the seed 1.2.0"
fi

# ---------------------------------------------------------------------------
# 2. Competing updates cannot regress: an older latest is refused while a
#    newer one publishes; the selection moves forward only.
# ---------------------------------------------------------------------------
out="$(docker exec -u vscode -e STUB_LATEST_STUB=1.0.0 "${b}" \
    bash /workspaces/glowcap/.devcontainer/bin/tools.sh update stub 2>&1)"
if [[ "${out}" == *"is current"* ]]; then
    pass
else
    fail "older upstream was not refused: ${out}"
fi
out="$(docker exec -u vscode -e STUB_LATEST_STUB=1.4.0 "${b}" \
    bash /workspaces/glowcap/.devcontainer/bin/tools.sh update stub 2>&1)"
if [[ "${out}" == *"installing 1.4.0"* ]]; then
    pass
else
    fail "newer upstream did not install: ${out}"
fi
if [[ "$(selection_version "${b}")" == "1.4.0" ]]; then
    pass
else
    fail "selection after competing updates is '$(selection_version "${b}")', expected 1.4.0"
fi

# ---------------------------------------------------------------------------
# 3. A warm reader survives an update: a process launched from the current
#    install keeps its files after another container publishes a new one.
# ---------------------------------------------------------------------------
old_selection="$(docker exec "${a}" bash -c \
    'readlink -f /home/vscode/.cache/glowcap/installed/linux-$(uname -m)/stub/current')"
out="$(docker exec -u vscode -e STUB_LATEST_STUB=1.5.0 "${b}" \
    bash /workspaces/glowcap/.devcontainer/bin/tools.sh update stub 2>&1)"
if [[ "${out}" == *"installing 1.5.0"* ]]; then
    pass
else
    fail "update under a warm reader failed: ${out}"
fi
if docker exec "${a}" test -x "${old_selection}/bin" 2>/dev/null; then
    pass
else
    fail "the warm reader's install vanished: ${old_selection}"
fi

# ---------------------------------------------------------------------------
# 4. An abruptly killed lock holder releases the lock and leaves the working
#    selection. docker kill is the harshest interruption: no traps run, the
#    holder's staging (allowed by the plan) dies with the container, and the
#    lock must be free for the survivor.
# ---------------------------------------------------------------------------
# Gate the 1.6.0 install so the kill lands mid-download, not after publish.
docker exec "${b}" touch /tmp/lockproof-gate >/dev/null 2>&1 || true
docker exec -u vscode -e STUB_LATEST_STUB=1.6.0 -d "${b}" \
    bash /workspaces/glowcap/.devcontainer/bin/tools.sh update stub >/dev/null 2>&1 || true
sleep 2
docker kill "${b}" >/dev/null 2>&1 || true
containers=("${a}")
sleep 0.5
out="$(docker exec -u vscode "${a}" bash -c \
    'GLOWCAP_TOOLS_LOCK_WAIT=3 /workspaces/glowcap/.devcontainer/bin/tools.sh ensure stub' 2>&1)"
if [[ "${out}" != *"holds the lock"* ]]; then
    pass
else
    fail "the lock did not release after the holder was killed"
fi
if [[ "$(selection_version "${a}")" == "1.5.0" ]]; then
    pass
else
    fail "selection after the kill is '$(selection_version "${a}")', expected the working 1.5.0"
fi

echo "tool-shared-cache: ${checks} checks, ${failures} failures"
if [[ "${failures}" -gt 0 ]]; then
    exit 1
fi
