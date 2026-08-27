/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../web/ui/session/projection.ts");
const { emptyRoomsSessionState } = await import("../lib/rooms_state.ts");
const store = await import("../web/ui/store.ts");
const { assertEquals } = await import("./assert.ts");
const { registrationId } = await import("./support/registration.ts");
const { roomsSessionSnapshot } = await import("./support/session_snapshot.ts");

Deno.test("an attached DM follows exact registration identity without losing selection", () => {
	store.set({
		...store.initial,
		activeKey: null,
		convs: new Map(),
		dirs: new Map(),
		drafts: new Map(),
		ignored: new Set(),
	});
	const projection = new AttachedSessionProjection();
	const direct = {
		kind: "direct" as const,
		id: "direct-id",
		directory: "directory",
		peer: "bo",
		peerRegistrationId: registrationId(1),
		closed: false,
		draft: "",
	};
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [direct],
		active: direct.id,
	};
	projection.apply(roomsSessionSnapshot({ checkpoint }));
	const before = store.activeConv();
	if (before?.type !== "dm") throw new Error("the attached identity fixture created no direct conversation");
	store.deliver(before.key, store.chatItem("bo", "old holder", false));

	projection.apply(roomsSessionSnapshot({
		revision: 1,
		checkpoint: {
			...checkpoint,
			conversations: [{ ...direct, peerRegistrationId: registrationId(2) }],
		},
	}));
	const after = store.activeConv();
	assertEquals(after?.type, "dm");
	assertEquals(after?.key === before.key, false);
	assertEquals(after?.persistId, direct.id);
	assertEquals(after?.type === "dm" ? after.peerRegistrationId : null, registrationId(2));
	assertEquals(after?.history.length, 0);
});
