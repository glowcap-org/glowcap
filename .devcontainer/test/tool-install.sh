#!/usr/bin/env bash
# Strict cold-seed proof for the managed tools: with a temporary empty
# install root and isolated configuration, every named harness installs its
# exact checkout seed through the real dispatcher, real PATH names, real
# downloads, real verification, and answers its seed version. A warm no-op
# proves nothing here; this gate exists because post-create only checks
# wiring and cannot establish that a seed bump is installable.
# Called by .github/workflows/agent-tools.yml, separately from product checks.
#
#   tool-install.sh <tool>...     (claude codex cursor-agent opencode)
#
# It never touches the shared cache (temporary root), never reads or writes
# real credentials (isolated configuration directories), and never sends a
# prompt to a vendor. Exit 0 only when every requested tool installed its
# exact seed and answered it. Runs inside the devcontainer; needs network.

set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -eq 0 ]]; then
    echo "usage: tool-install.sh <tool>... (e.g. claude codex cursor-agent opencode)" >&2
    exit 64
fi

# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_devcontainer_init "${dir}" checksums
glowcap_require_devcontainer "test/tool-install"

# shellcheck source=../tools/lib/registry.sh
source "${dir}/tools/lib/registry.sh"
platform="$(glowcap_devcontainer_tools_platform)"

failures=0
checks=0
fail() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    echo "tool-install: FAIL: $1" >&2
}
pass() {
    checks=$((checks + 1))
}

scratch=""
cleanup() {
    if [[ -n "${scratch}" ]]; then
        chmod -R u+w "${scratch}" 2>/dev/null || true
        rm -rf "${scratch}"
    fi
}
trap cleanup EXIT

scratch="$(mktemp -d)"
cache_root="${scratch}/installed"
bin_dir="${scratch}/bin"
state="${scratch}/state"
mkdir -p "${cache_root}" "${bin_dir}" "${state}"

# Every PATH name the registry manages answers through the real dispatcher.
for name in $(glowcap_tools_path_names); do
    ln -s "${dir}/tools/wrapper.sh" "${bin_dir}/${name}"
done

run_name() {
    env \
        GLOWCAP_TOOLS_CACHE_ROOT="${cache_root}" \
        CLAUDE_CONFIG_DIR="${state}/claude" \
        CODEX_HOME="${state}/codex" \
        CURSOR_CONFIG_DIR="${state}/cursor" \
        CURSOR_DATA_DIR="${state}/cursor" \
        XDG_CONFIG_HOME="${state}/xdg-config" \
        XDG_DATA_HOME="${state}/xdg-data" \
        npm_config_cache="${state}/npm-cache" \
        PATH="${bin_dir}:${PATH}" \
        "$@"
}

for tool in "$@"; do
    if ! glowcap_tools_registry_rows | grep -q "^${tool}|"; then
        fail "'${tool}' is not a managed tool"
        continue
    fi
    seed="$(GLOWCAP_TOOLS_CACHE_ROOT="${cache_root}" bash -c \
        "source '${dir}/lib/mod.sh' >/dev/null 2>&1; glowcap_devcontainer_init '${dir}' >/dev/null 2>&1; source '${dir}/tools/lib/registry.sh'; glowcap_tools_seed '${tool}'")" || seed=""
    if [[ -z "${seed}" ]]; then
        fail "'${tool}': cannot read its seed"
        continue
    fi
    started="$SECONDS"
    ok=1
    if [[ "${tool}" == "playwright" ]]; then
        # No PATH names: the pinned browser asset is proven through the exec
        # front, which must supply the private browser directory, resolve both
        # required Chromium forms through the shared resolver, match the
        # package's own executablePath, and launch them. The package version
        # must equal the checkout's pin (the requirement it was installed for).
        cat > "${scratch}/pw-proof.sh" <<'PROOF'
set -euo pipefail
browsers="${PLAYWRIGHT_BROWSERS_PATH:?the exec front did not supply PLAYWRIGHT_BROWSERS_PATH}"
# shellcheck source=../../lib/playwright.sh
source "${GLOWCAP_DEVCONTAINER_DIR}/lib/playwright.sh"
glowcap_playwright_binaries "${browsers}"
resolved="$(NODE_PATH="${browsers%/browser}/pkg/node_modules" node -e '
    const pw = require("playwright");
    const p = pw.chromium.executablePath();
    if (!p) { process.exit(1); }
    process.stdout.write(p + "\n" + require("playwright/package.json").version);
')"
resolved_path="$(head -1 <<<"${resolved}")"
pkg_version="$(tail -1 <<<"${resolved}")"
matched=""
for bin in "${playwright_bins[@]}"; do
    if [[ "$(dirname "${bin}")" == "$(dirname "${resolved_path}")" ]]; then matched=1; fi
    "${bin}" --version
done
[[ "${matched}" == 1 ]]
printf "pkg-version:%s\n" "${pkg_version}"
PROOF
        if ! out="$(run_name bash "${dir}/bin/tools.sh" exec playwright -- bash "${scratch}/pw-proof.sh" 2>"${scratch}/err-pw")"; then
            fail "'playwright': exec-front browser proof failed: $(tail -3 "${scratch}/err-pw")"
            ok=0
        fi
        if [[ "${out}" != *"pkg-version:${seed}"* ]]; then
            fail "'playwright': expected the pinned package to be ${seed} in: ${out}"
            ok=0
        else
            pass
        fi
        if [[ "${ok}" -eq 1 ]]; then
            pass
            echo "tool-install: playwright ${seed} cold-installed and launched on every browser form in $((SECONDS - started))s"
        fi
    fi
    for name in $(glowcap_tools_names_for "${tool}"); do
        if ! out="$(run_name "${name}" --version 2>"${scratch}/err-${name}")"; then
            fail "'${tool}' via '${name}': cold install or exec failed: $(tail -3 "${scratch}/err-${name}")"
            ok=0
            continue
        fi
        if [[ "${out}" != *"${seed}"* ]]; then
            fail "'${tool}' via '${name}': expected seed ${seed} in: ${out}"
            ok=0
        else
            pass
        fi
    done
    if [[ "${ok}" -eq 1 && "${tool}" != "playwright" ]]; then
        pass
        echo "tool-install: ${tool} ${seed} cold-installed and answered on every name in $((SECONDS - started))s"
    fi
    # The selection is a complete install: receipt policy, version, and, for
    # pinned assets, the requirement it was installed for. Seed tools publish
    # `current`; pinned tools publish `required/<requirement>`.
    if [[ "$(glowcap_tools_policy "${tool}")" == pinned ]]; then
        current="$(readlink -f "${cache_root}/${platform}/${tool}/required/${seed}" 2>/dev/null || true)"
    else
        current="$(readlink -f "${cache_root}/${platform}/${tool}/current" 2>/dev/null || true)"
    fi
    if [[ -z "${current}" ]]; then
        fail "'${tool}': no selection after cold install"
        continue
    fi
    receipt="$(cat "${current}/receipt" 2>/dev/null || true)"
    want_policy="seed"
    [[ "$(glowcap_tools_policy "${tool}")" == pinned ]] && want_policy="pinned"
    if [[ "${receipt}" != *"tool=${tool}"* || "${receipt}" != *"version=${seed}"* || "${receipt}" != *"policy=${want_policy}"* ]]; then
        fail "'${tool}': receipt does not record the exact seed install: ${receipt}"
    else
        pass
    fi
done

echo "tool-install: ${checks} checks, ${failures} failures"
if [[ "${failures}" -gt 0 ]]; then
    exit 1
fi
