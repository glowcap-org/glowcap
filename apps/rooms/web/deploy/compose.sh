#!/bin/sh
# One explicit Compose front for this deployment. The base topology is tracked;
# host exposure and extra networks are machine-local in the ignored override.
# Disable Compose's implicit .env discovery. Operator values arrive through the
# process environment unless the caller deliberately passes --env-file.
set -eu

deploy_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
base="$deploy_dir/docker-compose.yml"
override="$deploy_dir/docker-compose.override.yml"
export COMPOSE_DISABLE_ENV_FILE=1

if [ -f "$override" ]; then
	exec docker compose --project-directory "$deploy_dir" -f "$base" -f "$override" "$@"
fi
exec docker compose --project-directory "$deploy_dir" -f "$base" "$@"
