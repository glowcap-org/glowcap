// The lenient way into a room, against a directory that publishes no managers.
//
// `enterOrOpen` asks for a managed open first, because a caller that can be
// handed room and manager authority should get it. A directory serving without
// room links has no such authority to hand back, and the room still has to
// open: the links it returns are optional for exactly this reason.
//
// The demos are what caught this. Three of them serve a `RoomServer` with no
// links, and when the managed open became the only open they all stopped at the
// first room they tried to enter.

import { dial, loopbackTcpDesignator, roomsHost, roomsListen } from "../lib/locator.ts";
import { enterOrOpenResult } from "../lib/enter_room.ts";
import { NO_ROOM_MANAGERS, roomErrorOf } from "../lib/errors.ts";
import { Directory } from "../lib/room/client.ts";
import { RoomServer } from "../server/room_server.ts";
import { openRoomsRuntime } from "../lib/runtime.ts";
import { assertEquals } from "./assert.ts";

Deno.test({
	name: "a directory with no room managers still opens a room, and says so when asked directly",
	sanitizeOps: false,
	sanitizeResources: false,
	fn: async () => {
		const listener = await roomsListen("127.0.0.1", 0);
		const server = new RoomServer();
		const serving = server.serve(listener.host, listener);
		const host = roomsHost();
		const runtime = await openRoomsRuntime({ host });
		const dir = await Directory.connect(
			loopbackTcpDesignator(listener.port),
			(locator) => dial(locator, runtime),
		);
		try {
			// The strict verb refuses, and it refuses with a code rather than
			// prose, which is what lets the lenient one tell this apart from a
			// room that already exists.
			let refusal: string | undefined;
			try {
				await dir.openManaged("lobby");
			} catch (error) {
				refusal = roomErrorOf(error)?.code;
			}
			assertEquals(refusal, NO_ROOM_MANAGERS);

			const opened = await enterOrOpenResult(dir, "lobby");
			assertEquals(opened.opened, true);
			assertEquals(opened.managerLink, undefined, "a directory with no managers handed back authority");
			assertEquals(opened.roomLink, undefined);

			// And the room is real: entering it again finds it rather than opening
			// a second one, which is the ordinary path for everyone after the first.
			const entered = await enterOrOpenResult(dir, "lobby");
			assertEquals(entered.opened, false);
		} finally {
			await dir.close();
			await runtime.close();
			await listener.close();
			await serving.catch(() => {});
			await server.close();
		}
	},
});
