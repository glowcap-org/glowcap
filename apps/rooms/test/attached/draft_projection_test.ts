/// <reference lib="dom" />
import "../support/browser_application.ts";
import { emptyRoomsSessionState } from "../../lib/rooms_state.ts";
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { AttachedSessionProjection } = await import("../../web/ui/session/projection.ts");
const store = await import("../../web/ui/store.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");

Deno.test("unchanged checkpoints preserve draft identity and an in-progress edit", async () => {
	const { roomsSessionSnapshot } = await import("../support/session_snapshot.ts");
	const page = new RoomsPage();
	const projection = new AttachedSessionProjection(page);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "room",
			directory: "directory",
			name: "general",
			held: false,
			standing: null,
			draft: "draft",
		}],
	};
	projection.apply(roomsSessionSnapshot({ checkpoint }));
	const room = [...page.projection.get().convs.values()][0];
	const before = store.draftFor(page.projection, room.key);
	projection.apply(roomsSessionSnapshot({ checkpoint, revision: 1 }));
	if (store.draftFor(page.projection, room.key) !== before) {
		throw new Error("a snapshot echo superseded the pending submission");
	}
	store.switchTo(page.projection, room.key);
	store.startChange(page.projection, 42, "editing a posted line");
	const edit = store.activeDraft(page.projection);
	projection.apply(roomsSessionSnapshot({ checkpoint, revision: 2 }));
	if (store.activeDraft(page.projection) !== edit) {
		throw new Error("checkpoint draft overwrote an in-progress line edit");
	}
});
