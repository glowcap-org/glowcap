// A durable Rooms session keeps retrying a directory across absence, stop, and
// restart without pretending stale connectivity is live.

import { parseSturdyRef } from "@pancake/runtime";
import { RoomsSessionClient } from "../../lib/session/client.ts";
import { loopbackTcpDesignator, roomsAddress, roomsHost, roomsLocator } from "../../lib/locator.ts";
import { roomsPeerAuthority } from "../../lib/routes.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
import { stopOwned } from "../support/children.ts";
import {
	assert,
	dial,
	freePort,
	readPort,
	roomsTest,
	startStatefulServer,
	stopServer,
} from "../support/rooms_server.ts";
import { announcedSturdyref, startRoomsSessionPeer } from "../support/standalone_peer.ts";

roomsTest("a durable Rooms session retries a directory that was unavailable at startup", async () => {
	const directory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-retry-" });
	const roomDirectory = await Deno.makeTempDir({ prefix: "pancake-rooms-session-retry-room-" });
	const peerPort = freePort();
	const roomPort = freePort();
	const roomLocator = loopbackTcpDesignator(roomPort);
	const roomDirectoryId = roomsPeerAuthority(roomsLocator(roomLocator));
	const checkpointPath = `${directory}/checkpoint.json`;
	await Deno.writeTextFile(
		checkpointPath,
		JSON.stringify({
			...emptyRoomsSessionState(),
			directories: [{
				id: roomDirectoryId,
				locator: roomLocator,
				home: true,
				nick: "retrying-member",
				standing: null,
			}],
		}),
	);
	const peer = startRoomsSessionPeer(directory, peerPort, checkpointPath);
	let roomServer: Deno.ChildProcess | null = null;
	try {
		const link = await announcedSturdyref(peer, "ROOMS-SESSION-LISTENING", "retrying Rooms session peer");
		const parsed = parseSturdyRef(link, "v1_0");
		const session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		try {
			const client = new RoomsSessionClient(session, await session.enliven(link));
			assert(
				(await client.snapshot()).workspaceAdoption === "closed",
				"a supplied checkpoint left workspace adoption available",
			);
			assert(
				!(await client.snapshot()).connectedDirectories.includes(roomDirectoryId),
				"the unavailable directory was reported connected",
			);
			roomServer = startStatefulServer(roomPort, roomDirectory);
			await readPort(roomServer);
			let connected = false;
			for (let attempt = 0; attempt < 30; attempt += 1) {
				await new Promise((resolve) => setTimeout(resolve, 100));
				if ((await client.snapshot()).connectedDirectories.includes(roomDirectoryId)) {
					connected = true;
					break;
				}
			}
			assert(connected, "the durable session did not retry its unavailable directory");
			await stopServer(roomServer);
			roomServer = null;
			let disconnected = false;
			for (let attempt = 0; attempt < 30; attempt += 1) {
				await new Promise((resolve) => setTimeout(resolve, 100));
				if (!(await client.snapshot()).connectedDirectories.includes(roomDirectoryId)) {
					disconnected = true;
					break;
				}
			}
			assert(disconnected, "the durable session kept reporting a stopped directory as connected");
			roomServer = startStatefulServer(roomPort, roomDirectory);
			await readPort(roomServer);
			connected = false;
			for (let attempt = 0; attempt < 40; attempt += 1) {
				await new Promise((resolve) => setTimeout(resolve, 100));
				if ((await client.snapshot()).connectedDirectories.includes(roomDirectoryId)) {
					connected = true;
					break;
				}
			}
			assert(connected, "the durable session did not reconnect after the directory restarted");
		} finally {
			await session.close();
		}
	} finally {
		await stopOwned(peer);
		if (roomServer != null) await stopServer(roomServer);
		await Deno.remove(directory, { recursive: true });
		await Deno.remove(roomDirectory, { recursive: true });
	}
});
