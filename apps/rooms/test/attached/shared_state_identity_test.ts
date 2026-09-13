/// <reference lib="dom" />
// A session snapshot that changes nothing leaves the store's shared fields
// with the identity they had. The store promises that a line or a keystroke
// does not rebuild the shell; this holds the session side of that promise,
// where every snapshot used to replace seven maps and arrays wholesale and
// redraw every subscriber for a tick that moved nothing.

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { assertEquals } = await import("../assert.ts");
const { roomsSessionSnapshot } = await import("../support/session_snapshot.ts");

Deno.test("an unchanged session snapshot keeps every shared store field's identity", () => {
	const page = new RoomsPage();
	page.projection.set({
		...store.initialState(),
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
	});
	const projection = new AttachedSessionProjection(page);
	const room = {
		kind: "room" as const,
		id: "room-id",
		directory: "directory",
		name: "general",
		held: false,
		standing: null,
		draft: "unfinished",
	};
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [room],
		active: room.id,
	};
	projection.apply(roomsSessionSnapshot({ revision: 1, checkpoint }));
	const before = page.projection.get();
	projection.apply(roomsSessionSnapshot({ revision: 2, checkpoint }));
	const after = page.projection.get();
	for (const field of ["convs", "dirs", "drafts", "invites", "archiveShares", "ignored", "remembered"] as const) {
		assertEquals(before[field] === after[field], true, `an unchanged snapshot replaced \`${field}\``);
	}
});
