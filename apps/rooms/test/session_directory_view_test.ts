import type { RoomEvent, RoomInfo } from "../lib/directory_publications.ts";
import { DurableDirectoryView } from "../session/directory_view.ts";
import { assertEquals } from "./assert.ts";
import { registrationId } from "./support/registration.ts";

function room(id: string, count: number): RoomInfo {
	return { id, name: id, kind: "local", count, origin: "", proof: "local" };
}

Deno.test("a durable directory view projects publication and peer deltas by stable identity", () => {
	const view = new DurableDirectoryView("directory");
	view.replaceRooms([room("general", 1)]);
	view.apply({ kind: "registered", name: "Ada", registrationId: registrationId(1), count: 1, entry: null });
	view.apply({ kind: "registered", name: "ada", registrationId: registrationId(1), count: 1, entry: null });
	view.apply({ kind: "count", name: "general", count: 2, entry: room("general", 2) });
	view.apply({ kind: "opened", name: "elsewhere", count: 1, entry: room("elsewhere", 1) });
	assertEquals(view.snapshot(), {
		directoryId: "directory",
		rooms: [room("general", 2), room("elsewhere", 1)],
		peers: [{ name: "Ada", registrationId: registrationId(1) }],
		truncated: false,
	});
	assertEquals(view.snapshot(1), {
		directoryId: "directory",
		rooms: [room("general", 2)],
		peers: [],
		truncated: true,
	});
	view.apply({ kind: "unregistered", name: "ADA", registrationId: registrationId(1), count: 0, entry: null });
	view.apply({ kind: "closed", name: "general", count: 0, entry: room("general", 0) } as RoomEvent);
	assertEquals(view.snapshot(), {
		directoryId: "directory",
		rooms: [room("elsewhere", 1)],
		peers: [],
		truncated: false,
	});
	view.apply({ kind: "truncated", name: "", count: 4, entry: null });
	assertEquals(view.snapshot().truncated, true);
});
