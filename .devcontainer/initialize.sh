#!/usr/bin/env bash
# Host-side setup, run by devcontainer.json "initializeCommand" before the
# container is created. Runs on the host, where Docker lives. The
# in-container counterpart is post-create.sh.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${dir}/lib.sh"
pancake_require_host "initialize.sh"

if [[ ! -e "${dir}/.env" ]]; then
  bash "${dir}/configure.sh"
fi
worktree_name="$(pancake_devcontainer_validate_checkout_env "${dir}")"

command -v docker >/dev/null || {
  echo "initialize.sh: docker is not on PATH" >&2
  exit 1
}

# rooms-net is the fixed-name network this container shares with the rooms app
# (apps/rooms/web/deploy) so a bot here reaches the room's internal CapTP by
# name. Ignore a create race only when the network is observable afterward.
pancake_devcontainer_ensure_network rooms-net managed

egress="$(pancake_devcontainer_env_value "${dir}" EGRESS_NET)"
default_egress="$(pancake_devcontainer_default_egress_network "${worktree_name}")"
if [[ "${egress}" == "${default_egress}" ]]; then
  pancake_devcontainer_ensure_network "${egress}" managed
else
  pancake_devcontainer_ensure_network "${egress}" external
fi
