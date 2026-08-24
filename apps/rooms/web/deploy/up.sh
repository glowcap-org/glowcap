#!/bin/sh
# Bring the rooms deployment up fresh and say what an operator needs next:
# the room's locator, and every operator capability's swiss number, read from
# the state volume once the server has minted them. The same lines print in
# the container logs at startup; this saves fishing them out of scrollback.
#
#   ./up.sh
#
# Run from anywhere; it works in this directory. Needs docker compose on the
# host and the prebuilt libraries from `zig build rooms-deploy-prep`.
set -eu
cd "$(dirname "$0")"

docker compose up -d --build --force-recreate

printer="deno run --allow-read --allow-env --no-lock /repo/apps/rooms/server/capabilities.ts"

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
echo "rooms: operator capabilities (also in: docker compose logs rooms)"
echo ""
docker compose exec -T rooms $printer || {
	echo "rooms: the printer could not read the state volume; try: docker compose logs rooms"
	exit 1
}

echo ""
echo "rooms: the room's locator (what a terminal peer dials)"
echo ""
echo "$locator"
