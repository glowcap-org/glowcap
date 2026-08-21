#!/usr/bin/env bash
# Host-side setup, run by devcontainer.json "initializeCommand" before the
# container is created. Runs on the host, where Docker lives. The
# in-container counterpart is post-create.sh.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/mod.sh
source "${dir}/lib/mod.sh"
pancake_require_host "hooks/initialize.sh"

# Docker treats a missing bind source as a root-owned directory. Create each
# host-owned agent-state store first so every worktree mounts the same writable
# path for the current host user.
host_home="${HOME:?initialize.sh: HOME must name the host user directory}"
while IFS=: read -r host_relative _; do
  mkdir -p "${host_home}/${host_relative}"
done <<< "$(pancake_devcontainer_host_state_rows)"

# Containers read Claude Code's account file from inside the bound directory
# (CLAUDE_CONFIG_DIR in devcontainer.json), while a host Claude Code keeps its
# own beside it at the default path. Seed the shared copy from the host's once,
# so the first container after this lands is already recognized instead of
# opening on the login screen. Only when absent: after that the worktrees own
# it, and overwriting would discard their newer refreshed login.
if [[ -f "${host_home}/.claude.json" && ! -e "${host_home}/.claude/.claude.json" ]]; then
  cp "${host_home}/.claude.json" "${host_home}/.claude/.claude.json"
fi

# The container is Linux, so the agent reads tokens at ~/.config/cursor/auth.json.
# A Darwin host keeps them at ~/.cursor/auth.json instead. Copy that file into
# the Linux store once when the Linux path is empty, so a host login is already
# present the first time a container opens. After that each side refreshes its
# own copy, the same way a host Claude Code keeps ~/.claude.json beside the
# shared directory.
if [[ -f "${host_home}/.cursor/auth.json" && ! -e "${host_home}/.config/cursor/auth.json" ]]; then
  cp "${host_home}/.cursor/auth.json" "${host_home}/.config/cursor/auth.json"
fi

if [[ ! -e "${dir}/.env" ]]; then
  bash "${dir}/bin/configure.sh"
fi
worktree_name="$(pancake_devcontainer_validate_checkout_env "${dir}")"

command -v docker >/dev/null || {
  echo "hooks/initialize.sh: docker is not on PATH" >&2
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
