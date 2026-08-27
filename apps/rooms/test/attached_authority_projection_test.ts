/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../web/ui/session/projection.ts");
const { emptyRoomsSessionState } = await import("../lib/rooms_state.ts");
const store = await import("../web/ui/store.ts");
const { assertEquals } = await import("./assert.ts");
const { roomsSessionSnapshot } = await import("./support/session_snapshot.ts");

Deno.test("attached room authority changes preserve selection and conversation state", () => {
	store.set({
		...store.initial,
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
	});
	const projection = new AttachedSessionProjection();
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
	projection.apply(roomsSessionSnapshot({ checkpoint }));
	const before = [...store.get().convs.values()][0];
	if (before?.type !== "room") throw new Error("the attached authority fixture created no room");
	store.deliver(before.key, store.chatItem("bo", "before authority", false));

	const roomLink = "ocapn://directory.example/s/room";
	const moderator = "ocapn://directory.example/s/moderator";
	projection.apply(roomsSessionSnapshot({
		revision: 1,
		checkpoint: {
			...checkpoint,
			conversations: [{ ...room, link: roomLink, steward: moderator }],
		},
		roomViews: [{
			conversationId: room.id,
			members: [],
			topic: null,
			lineBytes: null,
			canModerate: true,
		}],
	}));
	const acquired = store.getConv(before.key);
	assertEquals(store.get().activeKey, before.key);
	assertEquals(acquired?.key, before.key);
	assertEquals(acquired?.history.length, 1);
	assertEquals(acquired?.type === "room" ? acquired.link : null, roomLink);
	assertEquals(acquired?.type === "room" ? acquired.steward : null, moderator);
	assertEquals(acquired?.type === "room" ? acquired.grants.has("steward") : false, true);

	projection.apply(roomsSessionSnapshot({ revision: 2, checkpoint }));
	const revoked = store.getConv(before.key);
	assertEquals(store.get().activeKey, before.key);
	assertEquals(revoked?.type === "room" ? revoked.link : null, undefined);
	assertEquals(revoked?.type === "room" ? revoked.steward : null, undefined);
});
