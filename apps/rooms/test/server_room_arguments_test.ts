import { Ref } from "@pancake/runtime";
import { loopbackTcpDesignator } from "../lib/locator.ts";
import {
	ATTACH,
	AWAY,
	CALLED,
	DIRECTORY,
	DISCARD,
	ENTER,
	HISTORY,
	LEAVE,
	LINK,
	LIST,
	OPEN,
	POST,
	POST_FILES,
	PRIVATE,
	STEWARD,
	TYPING,
} from "../lib/protocol.ts";
import { Directory, Room } from "../lib/room_client.ts";
import { assert, dial, roomsTest, withServer } from "./support/rooms_server.ts";

roomsTest("directory data verbs refuse surplus and contradictory arguments", async () => {
	await withServer(async (port) => {
		const session = await dial(loopbackTcpDesignator(port));
		session.serve().catch(() => {});
		try {
			const directory = await session.fetch(DIRECTORY);
			assert(
				await session.send(directory, OPEN, ["explicit-public", false]) instanceof Ref,
				"open refused its documented explicit public flag",
			);
			for (
				const [verb, args] of [
					[LIST, ["surplus"]],
					[OPEN, ["room", false, "not-a-private-recovery"]],
					[ENTER, ["room", "surplus"]],
				] as const
			) {
				let refused = false;
				try {
					await session.send(directory, verb, [...args]);
				} catch {
					refused = true;
				}
				assert(refused, `${verb} accepted invalid arguments`);
			}
		} finally {
			await session.close();
		}
	});
});

roomsTest("room data verbs refuse missing, surplus, and contradictory arguments", async () => {
	await withServer(async (port) => {
		const directory = await Directory.connect(loopbackTcpDesignator(port), (address) => dial(address));
		const room = await Room.subscribe(directory.session, await directory.open("exact-room"), "reader");
		try {
			for (
				const [verb, args] of [
					[POST, []],
					[POST_FILES, []],
					[ATTACH, ["file", "text/plain", 1n, 1n]],
					[TYPING, ["yes"]],
					[HISTORY, ["surplus"]],
					[STEWARD, ["surplus"]],
					[CALLED, ["surplus"]],
					[PRIVATE, ["surplus"]],
					[LINK, ["surplus"]],
					[AWAY, []],
					[LEAVE, ["surplus"]],
				] as const
			) {
				let refused = false;
				try {
					await directory.session.send(room.reference, verb, [...args]);
				} catch {
					refused = true;
				}
				assert(refused, `${verb} accepted invalid arguments`);
			}
			const upload = await directory.session.send(room.reference, ATTACH, ["exact.txt", "text/plain", 1n]);
			assert(upload instanceof Ref, "attach did not answer an upload capability");
			let refusedDiscard = false;
			try {
				await directory.session.send(upload, DISCARD, ["surplus"]);
			} catch {
				refusedDiscard = true;
			}
			assert(refusedDiscard, "discard accepted surplus data");
			await directory.session.send(upload, DISCARD, []);
			await room.say("still joined after refused leave");
		} finally {
			await room.leave();
			await directory.close();
		}
	});
});
