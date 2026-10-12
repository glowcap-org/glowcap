// A live room generation owns its line numbers. Retained text survives a room
// ending. Those mutation names do not, because the next generation starts its
// counter at one again.

/// <reference lib="dom" />

import { assertEquals } from "../assert.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const store = await import("../../web/ui/store.ts");
const projection = new store.PageProjection();
const { dirId } = await import("../../web/ui/types.ts");

Deno.test("a retired room generation cannot retarget a reused line number", () => {
	const room = store.ensureRoom(projection, dirId("test-dir"), "generation");
	const oldLine = { ...store.chatItem(projection, "alice", "old generation", false), lineId: 1 };
	store.deliver(projection, room.key, oldLine);
	store.retireRoomLineIds(projection, room.key);
	const newLine = { ...store.chatItem(projection, "alice", "new generation", false), lineId: 1 };
	store.deliver(projection, room.key, newLine);
	store.applyLineChange(projection, room.key, 1, { text: "new generation edited", edited: true });

	const history = store.historyOf(projection, room.key);
	const oldAfter = history.find((item) => item.id === oldLine.id);
	const newAfter = history.find((item) => item.id === newLine.id);
	assertEquals(oldAfter?.kind === "chat" ? oldAfter.text : null, "old generation");
	assertEquals(newAfter?.kind === "chat" ? [newAfter.text, newAfter.edited] : null, [
		"new generation edited",
		true,
	]);
	store.forgetConv(projection, room.key);
});
