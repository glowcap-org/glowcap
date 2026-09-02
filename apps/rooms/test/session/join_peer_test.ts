// Process proof for joining a directory through an initially empty durable session.

import { parseSturdyRef } from "@glowcap/runtime";
import { RoomsSessionClient } from "../../lib/session/client.ts";
import { loopbackTcpDesignator, roomsAddress, roomsHost, roomsLocator } from "../../lib/locator.ts";
import { roomsPeerAuthority } from "../../lib/routes.ts";
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

roomsTest("an empty durable Rooms session realizes its first directory and room", async () => {
	const sessionState = await Deno.makeTempDir({ prefix: "glowcap-rooms-session-join-" });
	const directoryState = await Deno.makeTempDir({ prefix: "glowcap-rooms-session-join-directory-" });
	const sessionPort = freePort();
	const directoryPort = freePort();
	const directoryServer = startStatefulServer(directoryPort, directoryState);
	let sessionPeer: Deno.ChildProcess | null = null;
	try {
		await readPort(directoryServer);
		const locator = loopbackTcpDesignator(directoryPort);
		const directoryId = roomsPeerAuthority(roomsLocator(locator));
		sessionPeer = startRoomsSessionPeer(sessionState, sessionPort);
		const sturdyref = await announcedSturdyref(
			sessionPeer,
			"ROOMS-SESSION-LISTENING",
			"empty Rooms session peer",
		);
		const parsed = parseSturdyRef(sturdyref, "v1_0");
		const session = await dial(roomsAddress(parsed.locator), roomsHost(undefined, "interop"));
		try {
			const client = new RoomsSessionClient(
				session,
				await session.enliven(sturdyref),
			);
			const initial = await client.snapshot();
			assert(initial.checkpoint.directories.length === 0, "a new durable session was not empty");
			const conversationId = crypto.randomUUID();
			await client.joinRoom("join-first-room", initial.revision, {
				locator,
				nick: "first-member",
				conversation: {
					kind: "room",
					id: conversationId,
					directory: directoryId,
					name: "first-room",
					held: false,
					standing: null,
					draft: "",
				},
			});
			let realized = false;
			let latest = await client.snapshot();
			for (let attempt = 0; attempt < 40; attempt += 1) {
				if (
					latest.connectedDirectories.includes(directoryId) &&
					latest.roomViews.some((room) => room.conversationId === conversationId)
				) {
					realized = true;
					break;
				}
				await new Promise((resolve) => setTimeout(resolve, 100));
				latest = await client.snapshot();
			}
			const issue = latest.issues.find((entry) => entry.subject === `directory:${directoryId}`)?.reason;
			assert(realized, `the first directory intent was not realized${issue == null ? "" : `: ${issue}`}`);
		} finally {
			await session.close();
		}
	} finally {
		if (sessionPeer != null) await stopOwned(sessionPeer);
		await stopServer(directoryServer);
		await Deno.remove(sessionState, { recursive: true });
		await Deno.remove(directoryState, { recursive: true });
	}
});
