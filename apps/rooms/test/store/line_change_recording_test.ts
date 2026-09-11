// A room saying a line was edited or withdrawn is the line changing, exactly as
// a reader's own edit is: the archive recorder hears both through the one
// line-change seam, so a kept copy cannot outlive the takedown it claims to
// follow. A change naming a line this window never held records nothing.

/// <reference lib="dom" />

import { assertEquals } from "../assert.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/types.ts");

Deno.test("a room's edit and withdrawal reach the line recorder", () => {
	const projection = new store.PageProjection();
	const room = store.ensureRoom(projection, dirId("test-dir"), "recording");
	const recorded: { id: number; text: string; change?: string }[] = [];
	projection.setLineRecorder((conv, item, change) => {
		if (conv.key !== room.key || item.kind !== "chat") return;
		recorded.push({ id: item.id, text: item.text, change });
	});

	const line = { ...store.chatItem(projection, "alice", "the first words", false), lineId: 7 };
	store.deliver(projection, room.key, line);
	store.applyLineChange(projection, room.key, 7, { text: "the better words", edited: true });
	store.applyLineChange(projection, room.key, 7, { withdrawn: true });
	// A change naming a line nobody here holds is not an error and records nothing.
	store.applyLineChange(projection, room.key, 99, { text: "nobody's line", edited: true });

	assertEquals(recorded, [
		{ id: line.id, text: "the first words", change: undefined },
		{ id: line.id, text: "the better words", change: "edited" },
		{ id: line.id, text: "the better words", change: "withdrawn" },
	]);
	const shown = store.historyOf(projection, room.key).find((item) => item.id === line.id);
	assertEquals(shown?.kind === "chat" ? [shown.text, shown.withdrawn] : null, ["the better words", true]);
	projection.setLineRecorder(null);
	store.forgetConv(projection, room.key);
});
