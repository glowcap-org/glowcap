#!/usr/bin/env bash
# A flaky fetch succeeds on a later attempt, and a dead one reports its last status.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/fetch.sh
source "${dir}/lib/fetch.sh"

scratch="$(mktemp -d)"
trap 'rm -rf -- "${scratch}"' EXIT
export GLOWCAP_RETRY_PAUSE_SECONDS=0

# Fails until its counter file holds the wanted number of calls.
cat > "${scratch}/flaky" <<'SCRIPT'
#!/usr/bin/env bash
calls="$(($(cat "$1" 2>/dev/null || echo 0) + 1))"
echo "${calls}" > "$1"
[[ "${calls}" -ge "$2" ]] || exit 7
SCRIPT
chmod +x "${scratch}/flaky"

expect() {
    local label="$1" wanted="$2" got="$3"
    if [[ "${got}" != "${wanted}" ]]; then
        echo "fetch-retry: ${label}: wanted ${wanted}, got ${got}" >&2
        exit 1
    fi
}

glowcap_retry 3 "${scratch}/flaky" "${scratch}/recovers" 3 2> /dev/null
expect "a third attempt that succeeds ends the retry" 3 "$(cat "${scratch}/recovers")"

status=0
glowcap_retry 2 "${scratch}/flaky" "${scratch}/dead" 9 2> "${scratch}/dead.log" || status=$?
expect "a command that never succeeds answers its own status" 7 "${status}"
expect "the attempts stop at the limit" 2 "$(cat "${scratch}/dead")"
grep -Fq "failed 2 times (last exit 7)" "${scratch}/dead.log"

status=0
glowcap_retry 0 "${scratch}/flaky" "${scratch}/never" 1 2> /dev/null || status=$?
expect "no attempts is a failure" 1 "${status}"
expect "no attempts runs nothing" missing "$(cat "${scratch}/never" 2> /dev/null || echo missing)"

printf '%s\n' 'fetch-retry: a failed fetch is retried within its bounds'
