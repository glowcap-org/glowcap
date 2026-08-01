#!/usr/bin/env bash
# Host-side setup, run by devcontainer.json "initializeCommand" before the
# container is created. Runs on the host, where Docker and $HOME live — the
# in-container counterpart is post-create.sh.
set -euo pipefail

# Bind-mount sources must exist before Docker mounts them, or Docker creates a
# root-owned directory (or a directory where a file bind was intended). These
# carry tool logins/state that should survive a rebuild — see devcontainer.json.
mkdir -p "${HOME}/.claude" "${HOME}/.config/gh" \
  "${HOME}/.local/share/opencode" "${HOME}/.config/opencode" \
  "${HOME}/.config/agents"

# rooms-net is the fixed-name network this container shares with the rooms app
# (apps/rooms/web/deploy) so a bot here reaches the room's internal
# CapTP by name. Create it if missing so compose can attach; ignore "exists".
docker network create rooms-net 2>/dev/null || true
