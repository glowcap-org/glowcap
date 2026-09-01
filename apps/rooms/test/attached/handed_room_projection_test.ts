/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
const { CapabilitySetEvents } = await import("../../web/ui/ops/capability_set_events.ts");
const { emptyRoomsSessionState } = await import("../../lib/rooms_state.ts");
const { roomsSessionSnapshot } = await import("../support/session_snapshot.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const { assertEquals } = await import("../assert.ts");

Deno.test("an attached view receives transient handed rooms outside its checkpoint", () => {
	const page = new RoomsPage();
	const directory = "ocapn://directory.id";
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: directory, locator: directory, home: true, nick: "ada", standing: null }],
	};
	const projection = new AttachedSessionProjection(page, null, new CapabilitySetEvents());
	projection.apply(roomsSessionSnapshot({
		checkpoint,
		handedRooms: [{ id: "handed-room:1", directory, label: "plans", from: "bo" }],
	}));
	assertEquals(page.projection.get().invites, [{
		id: "handed-room:1",
		dir: directory,
		way: "handed",
		label: "plans",
		from: "bo",
		link: "",
	}]);
	projection.apply(roomsSessionSnapshot({ checkpoint, handedRooms: [] }));
	assertEquals(page.projection.get().invites, []);
});
