#!/usr/bin/env bash
# Confirm this container carries the environment its Compose service declares.
#
# Compose applies these when a container is created, so a container that
# predates a newly declared variable keeps running without it and the service
# that wanted it falls back to its own default. That is silent and it points
# somewhere else: adding GLOWCAP_ROOMS_DEV_HOST left older containers running
# the Rooms dev server on container loopback, which a published port cannot
# reach, and the failure arrived as a 502 from the proxy in front of it.
#
# Called by hooks/post-create.sh, so a container that has fallen behind says so
# when it opens rather than when something built on it fails. Only literal
# values are checked; a `${...}` value is the host's .env to fill and varies
# per worktree.
#
# Reads docker-compose.yml beside it and the running environment. Writes what
# drifted to stderr and exits non-zero; writes nothing when they agree.

set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
glowcap_require_devcontainer "hooks/verify-compose-env"

compose_file="${dir}/docker-compose.yml"
unset_marker="__glowcap_compose_env_unset__"
drifted=0

while IFS=$'\t' read -r name want; do
    [[ -n "${name}" ]] || continue
    have="${!name-${unset_marker}}"
    if [[ "${have}" == "${unset_marker}" ]]; then
        echo "hooks/verify-compose-env: ${name} is unset; docker-compose.yml declares ${name}=${want}" >&2
        drifted=1
    elif [[ "${have}" != "${want}" ]]; then
        echo "hooks/verify-compose-env: ${name} is ${have}; docker-compose.yml declares ${want}" >&2
        drifted=1
    fi
done < <(awk '
    /^    environment:/ { inside = 1; next }
    inside && /^    [^ ]/ { inside = 0 }
    inside && /^      [A-Za-z_][A-Za-z0-9_]*:/ {
        entry = $0
        sub(/^      /, "", entry)
        at = index(entry, ":")
        key = substr(entry, 1, at - 1)
        value = substr(entry, at + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", value)
        if (value ~ /\$\{/) next
        gsub(/^"|"$/, "", value)
        printf "%s\t%s\n", key, value
    }
' "${compose_file}")

if (( drifted )); then
    echo "hooks/verify-compose-env: this container was created before the current" \
        "docker-compose.yml. Rebuild it; a variable set by hand fixes one shell only." >&2
    exit 1
fi
