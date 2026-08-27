#!/bin/sh
# Bring the rooms deployment up fresh and say what an operator needs next:
# the room's locator, every directory-operator capability, and the durable
# workspace's administrator sturdyref. This saves fishing bearer authority out
# of container logs and says which UI control receives it.
#
#   ./up.sh
#
# Run from anywhere; it works in this directory. Needs docker compose on the
# host and the prebuilt libraries from `zig build rooms-deploy-prep`.
set -eu
cd "$(dirname "$0")"

docker compose up -d --build --force-recreate

printer="deno run --allow-read --allow-env --no-lock /repo/apps/rooms/server/capabilities.ts"
session_printer="deno run --allow-read=/run/rooms-session --no-lock /repo/apps/rooms/web/deploy/session_healthcheck.ts --print"

# The capability files persist in the state volume, so they answer instantly
# even while a recreated server is still booting. The locator is the real
# "serving" signal — the same fact the healthcheck probes — so it is what
# this waits for, and everything prints once it answers.
echo ""
echo "rooms: waiting for the server to serve..."
locator=$(docker compose exec -T rooms deno eval --no-lock '
	for (let tries = 0; tries < 60; tries++) {
		try {
			const answer = await fetch("http://127.0.0.1:8000/locator");
			if (answer.ok) {
				console.log((await answer.text()).trim());
				Deno.exit(0);
			}
		} catch {
			// Booting: the port is not answering yet.
		}
		await new Promise((resolve) => setTimeout(resolve, 2000));
	}
	Deno.exit(1);
') || {
	echo "rooms: the server did not start serving in two minutes; read: docker compose logs rooms"
	exit 1
}

echo ""
echo "rooms: waiting for the shared session to serve..."
session_capability=""
tries=0
while [ "$tries" -lt 60 ]; do
	if session_capability=$(docker compose exec -T rooms-session $session_printer 2>/dev/null); then
		break
	fi
	tries=$((tries + 1))
	sleep 2
done
if [ -z "$session_capability" ]; then
	echo "rooms: the shared session did not start serving in two minutes; read: docker compose logs rooms-session"
	exit 1
fi

directory_capabilities=$(docker compose exec -T rooms $printer) || {
	echo "rooms: the printer could not read the state volume; try: docker compose logs rooms"
	exit 1
}

# Keep the bearer authorities in one deliberate handoff. In particular, do
# not let the capability printer stream its lines among Compose progress or
# readiness messages: an operator should be able to copy or save this block
# as one value.
printf '\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n%s\n' \
	"rooms: deployment handoff" \
	"Directory operator capabilities:" \
	"$directory_capabilities" \
	"Room locator (what a terminal peer dials):" \
	"$locator" \
	"Shared-session administrator capability:" \
	"Paste this into Choose a session -> Shared session; it grants full control of that workspace." \
	"$session_capability"
