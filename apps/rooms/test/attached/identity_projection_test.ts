// Direct-message projection follows exact registration identity while preserving the selected conversation.
/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { assertEquals } = await import("../assert.ts");
const { registrationId } = await import("../support/registration.ts");
const { roomsSessionSnapshot } = await import("../support/session_snapshot.ts");

Deno.test("an attached DM follows exact registration identity without losing selection", () => {
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
	const before = store.activeConv(page.projection);
	if (before?.type !== "dm") throw new Error("the attached identity fixture created no direct conversation");
	store.deliver(page.projection, before.key, store.chatItem(page.projection, "bo", "old holder", false));

	projection.apply(roomsSessionSnapshot({
		revision: 1,
		checkpoint: {
			...checkpoint,
			conversations: [{ ...direct, peerRegistrationId: registrationId(2) }],
		},
	}));
	const after = store.activeConv(page.projection);
	assertEquals(after?.type, "dm");
	assertEquals(after?.key === before.key, false);
	assertEquals(after?.type === "directory" ? null : after?.persistId, direct.id);
	assertEquals(after?.type === "dm" ? after.peerRegistrationId : null, registrationId(2));
	assertEquals(store.historyOf(page.projection, after?.key ?? "").length, 0);
});
