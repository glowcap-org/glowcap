// A room row's identity survives its publication becoming known. A room
// joined by link starts with no publication id. The durable session backfills
// the resolved id at a later reconcile, and the rail must keep showing one
// row with its history rather than a second, empty sibling filed under the
// publication key. A row already claiming a different publication is a
// different room and stays its own row.

/// <reference lib="dom" />

import "../support/match_media.ts";
import "../support/browser_application.ts";
import { assertEquals } from "../assert.ts";

const store = await import("../../web/ui/store.ts");
const projection = new store.PageProjection();
const { dirId } = await import("../../web/ui/directory.ts");

Deno.test("a publication backfill adopts the room row instead of minting a sibling", () => {
	const dir = dirId("backfill-dir");
	const joined = store.ensureRoom(projection, dir, "#chan", { persistId: "conv-1" });
	store.deliver(projection, joined.key, store.chatItem(projection, "alice", "before the restart", false));

	const restored = store.ensureRoom(projection, dir, "#chan", { persistId: "conv-1", publicationId: "pub-7" });
	assertEquals(restored.key, joined.key);
	assertEquals(restored.publicationId, "pub-7");
	assertEquals(store.joinedRooms(projection, dir).length, 1);
	const history = store.historyOf(projection, restored.key);
	assertEquals(history.some((item) => item.kind === "chat" && item.text === "before the restart"), true);
	store.forgetConv(projection, restored.key);
});

Deno.test("a publication join adopts the publication-less row of the same name", () => {
	const dir = dirId("adopt-dir");
	const linked = store.ensureRoom(projection, dir, "#bridge");
	const entered = store.ensureRoom(projection, dir, "#bridge", { publicationId: "pub-9" });
	assertEquals(entered.key, linked.key);
	assertEquals(store.joinedRooms(projection, dir).length, 1);
	store.forgetConv(projection, entered.key);
});

Deno.test("a name entry adopts the publication-keyed row of the same name", () => {
	const dir = dirId("name-adopt-dir");
	const published = store.ensureRoom(projection, dir, "#chan", { publicationId: "pub-3" });
	const named = store.ensureRoom(projection, dir, "#chan");
	assertEquals(named.key, published.key);
	assertEquals(store.joinedRooms(projection, dir).length, 1);
	store.forgetConv(projection, named.key);
});

Deno.test("a different publication under one name stays its own room", () => {
	const dir = dirId("collision-dir");
	const first = store.ensureRoom(projection, dir, "#chan", { publicationId: "pub-a" });
	const second = store.ensureRoom(projection, dir, "#chan", { publicationId: "pub-b" });
	assertEquals(first.key === second.key, false);
	assertEquals(store.joinedRooms(projection, dir).length, 2);
	store.forgetConv(projection, first.key);
	store.forgetConv(projection, second.key);
});

Deno.test("/link names only the listed rooms this tab holds on the directory", () => {
	const dir = dirId("listed-dir");
	const elsewhere = dirId("listed-elsewhere");
	const listed = store.ensureRoom(projection, dir, "lobby", { persistId: "conv-listed" });
	const hidden = store.ensureRoom(projection, dir, "~0001", { persistId: "conv-private", held: true });
	const other = store.ensureRoom(projection, elsewhere, "lobby", { persistId: "conv-other" });
	assertEquals(store.listedRoomsOn(projection.get().convs, dir).map((room) => room.id), ["lobby"]);
	for (const room of [listed, hidden, other]) store.forgetConv(projection, room.key);
});
