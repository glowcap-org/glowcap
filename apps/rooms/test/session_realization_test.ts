import { durableTypingTarget, waitForLiveRealization } from "../session/realization.ts";
import { assertEquals } from "./assert.ts";

Deno.test("typing resolves the matching live room or direct owner", () => {
	const room = { room: {} as import("../lib/room_client.ts").Room };
	const direct = { line: {} as import("../lib/direct_message.ts").DirectMessage };
	const directories = new Map([[
		"directory",
		{ roomRealization: { rooms: new Map([["room", room]]) }, directs: new Map([["direct", direct]]) },
	]]) as unknown as Parameters<typeof durableTypingTarget>[0];
	const roomTarget = durableTypingTarget(directories, "room");
	const directTarget = durableTypingTarget(directories, "direct");
	assertEquals(roomTarget != null && "room" in roomTarget && roomTarget.room === room.room, true);
	assertEquals(directTarget != null && "direct" in directTarget && directTarget.direct === direct, true);
	assertEquals(durableTypingTarget(directories, "missing"), null);
});

Deno.test("room offer realization waits for the owned reconciliation turn", async () => {
	let realized: string | null = null;
	let resolve!: () => void;
	const pending = new Promise<void>((finish) => resolve = finish);
	const wait = waitForLiveRealization(() => realized, pending, 100);
	await new Promise((finish) => setTimeout(finish, 0));
	realized = "direct";
	resolve();
	assertEquals(await wait, "direct");
});
