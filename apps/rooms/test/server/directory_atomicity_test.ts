// Directory mutations either return the authority they promise or leave no
// room/name/quota state behind.

import { Ref, type Session } from "@glowcap/runtime";
import { directoryBehavior, openNewRoom } from "../../server/directory_behavior.ts";
import { loopbackTcpDesignator, roomsHost, roomsListen } from "../../lib/locator.ts";
import { DIRECTORY, LIST, OPEN_MANAGED } from "../../lib/protocol.ts";
import { RoomLinks } from "../../server/room_links.ts";
import { RoomServer } from "../../server/room_server.ts";
import { assert, dial, roomsTest } from "../support/rooms_server.ts";
import { newManagedRoomId } from "../../lib/limits.ts";

function testRef(): Ref {
	return Object.create(Ref.prototype) as Ref;
}

Deno.test("managed room preparation is atomic across both returned capabilities", () => {
	const roomServer = new RoomServer();
	const released: Ref[] = [];
	let spawns = 0;
	const session = {
		spawn: () => {
			spawns += 1;
			if (spawns === 2) throw new Error("hosted object budget exhausted");
			return testRef();
		},
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;
	const state = roomServer.live.makeRoomState("atomic-manager-opening", session);
	const managerLinks = Object.create(RoomLinks.prototype) as RoomLinks;
	let refused = false;
	try {
		openNewRoom(roomServer, session, state, managerLinks, managerLinks);
	} catch {
		refused = true;
	}
	assert(refused, "managed room preparation survived a missing manager capability");
	assert(roomServer.live.rooms.get(state.key) !== state, "a partially prepared managed room was registered");
	assert(released.length === 1, "the prepared room capability was not returned after manager issuance failed");
});

Deno.test("a refused room registration returns every prepared capability", () => {
	const roomServer = new RoomServer();
	const released: Ref[] = [];
	const session = {
		spawn: () => testRef(),
		release: (ref: Ref) => released.push(ref),
	} as unknown as Session;
	const existing = roomServer.live.makeRoomState("atomic-registration", session);
	roomServer.live.registerRoom(existing);
	try {
		const duplicate = roomServer.live.makeRoomState("ATOMIC-REGISTRATION", session);
		const managerLinks = Object.create(RoomLinks.prototype) as RoomLinks;
		let refused = false;
		try {
			openNewRoom(roomServer, session, duplicate, managerLinks, managerLinks);
		} catch {
			refused = true;
		}
		assert(refused, "duplicate room registration unexpectedly succeeded");
		assert(released.length === 2, "a refused registration retained returned room capabilities");
	} finally {
		roomServer.live.forgetRoom(existing);
	}
});

roomsTest("managed open refuses before registering when manager issuance is absent", async () => {
	const roomServer = new RoomServer();
	const server = await roomsListen("127.0.0.1", 0, roomsHost());
	const serving = (async () => {
		for await (const accepted of server) {
			accepted.publish(DIRECTORY, directoryBehavior(roomServer));
			void accepted.serve().catch(() => {});
		}
	})();
	const session = await dial(loopbackTcpDesignator(server.port));
	try {
		const directory = await session.fetch(DIRECTORY);
		let refused = false;
		try {
			await session.send(directory, OPEN_MANAGED, [
				"must-not-register",
				"listed",
				"open",
				"open",
				newManagedRoomId(),
			]);
		} catch {
			refused = true;
		}
		assert(refused, "managed open succeeded without manager issuance");
		const listed = await session.send(directory, LIST, []) as unknown[][];
		assert(!listed.some((row) => row[0] === "must-not-register"), "failed managed open occupied the room name");
	} finally {
		await session.close();
		server.close();
		await serving;
		await roomServer.close();
	}
});
