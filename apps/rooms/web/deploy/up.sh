#!/bin/sh
# Bring the rooms deployment up fresh and say what an operator needs next:
# the room's locator, browser interface build, every directory-operator
# capability, and the durable workspace's administrator sturdyref. This saves
# fishing bearer authority out of container logs and says which UI control
# receives it.
#
#   ./up.sh
#
# Run from anywhere; it works in this directory. Needs Docker Compose on the
# host and the prebuilt libraries from `zig build rooms-deploy-prep`.
set -eu
cd "$(dirname "$0")"
compose="./compose.sh"
repo_root=$(CDPATH= cd -- ../../../.. && pwd)
deployment_version="$repo_root/zig-out/rooms-deployment.version"

if [ -n "$(git -C "$repo_root" status --porcelain)" ]; then
	echo "rooms: refusing to deploy a checkout with local changes"
	echo "rooms: commit the intended source, then run: zig build rooms-deploy-prep"
	exit 1
fi
source_version=$(git -C "$repo_root" rev-parse --short=12 HEAD)
prepared_version=$(sed -n '1p' "$deployment_version" 2>/dev/null || true)
if [ "$prepared_version" != "$source_version" ]; then
	echo "rooms: prepared deployment ${prepared_version:-missing} does not match checkout $source_version"
	echo "rooms: run: zig build rooms-deploy-prep"
	exit 1
fi

browser_version=$(sed -n '2p' "$deployment_version")
selected_version=$(cat "$repo_root/zig-out/rooms-web/current/source.version" 2>/dev/null || true)
if [ -z "$browser_version" ] || [ "$selected_version" != "$browser_version" ]; then
	echo "rooms: selected browser assets do not match the prepared deployment"
	echo "rooms: run: zig build rooms-deploy-prep"
	exit 1
fi

# Bound every post-health Docker read too. A container can wedge after its last
# probe, and a retry count around an unbounded Compose exec is not a
# deadline. TERM gives the CLI a moment to unwind; KILL makes the bound hard.
bounded_exec() {
	"$@" &
	command_pid=$!
	(
		sleep 15
		kill -TERM "$command_pid" 2>/dev/null || exit 0
		sleep 2
		kill -KILL "$command_pid" 2>/dev/null || true
	) &
	timer_pid=$!
	if wait "$command_pid"; then
		result=0
	else
		result=$?
	fi
	kill -TERM "$timer_pid" 2>/dev/null || true
	wait "$timer_pid" 2>/dev/null || true
	return "$result"
}

# Both services allow a 90-second cold-start period, then three 30-second
# health intervals with bounded 10-second probes. Keep Compose's outer deadline
# beyond that declared budget so a service cannot be failed just before its
# final useful probe, while remaining decisively finite.
if ! "$compose" up -d --build --force-recreate --wait --wait-timeout 210; then
	echo "rooms: the deployment did not become healthy within its 210-second health budget"
	echo "rooms: read: $compose logs rooms rooms-session"
	exit 1
fi

printer="/runtime/bin/rooms-server --capabilities"
session_printer="/runtime/bin/rooms-session --check-ready=/run/rooms-session/admin.sturdyref"

# Compose has already joined both declared healthchecks. Read each ready value
# once rather than maintaining a second polling state machine whose individual
# Compose exec can outlive its nominal retry budget.
locator=$(bounded_exec "$compose" exec -T rooms /runtime/bin/rooms-web --locator) || {
	echo "rooms: the healthy server did not answer its locator; read: $compose logs rooms"
	exit 1
}

ui_version=$(bounded_exec "$compose" exec -T rooms /runtime/bin/rooms-web --ui-version) || {
	echo "rooms: the healthy server did not answer its UI version; read: $compose logs rooms"
	exit 1
}

# Compose can still be reporting the last successful health probe while the
# session runtime is between internal incarnations. Its tmpfs marker is removed
# before each retry, so retry this one read through a fixed, bounded window
# instead of turning that honest gap into a failed deployment handoff.
read_session_capability() {
	attempt=1
	while [ "$attempt" -le 6 ]; do
		if capability=$(bounded_exec "$compose" exec -T rooms-session $session_printer 2>/dev/null) &&
			[ -n "$capability" ]; then
			printf '%s\n' "$capability"
			return 0
		fi
		[ "$attempt" -eq 6 ] && return 1
		attempt=$((attempt + 1))
		sleep 2
	done
}

session_capability=$(read_session_capability) || {
	echo "rooms: the healthy shared session did not expose its administrator capability; read: $compose logs rooms-session"
	exit 1
}

directory_capabilities=$(bounded_exec "$compose" exec -T rooms $printer) || {
	echo "rooms: the printer could not read the state volume; try: $compose logs rooms"
	exit 1
}

# Keep the bearer authorities in one deliberate handoff. In particular, do
# not let the capability printer stream its lines among Compose progress or
# readiness messages: an operator should be able to copy or save this block
# as one value.
printf '\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n%s\n' \
	"rooms: deployment handoff" \
	"Directory operator capabilities:" \
	"$directory_capabilities" \
	"Room locator (what a terminal peer dials):" \
	"$locator" \
	"Browser interface build (shown at the bottom of Help):" \
	"$ui_version" \
	"Shared-session administrator capability:" \
	"Paste this into Choose a session -> Shared session; it grants full control of that workspace." \
	"$session_capability"
