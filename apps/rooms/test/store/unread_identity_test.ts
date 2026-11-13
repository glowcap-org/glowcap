// A line into the conversation being read leaves the unreads map alone, so a
// subscriber that selects the whole map does not redraw for it. A mark that
// does change still replaces the map.
import "../support/match_media.ts";
import "../support/browser_application.ts";
import { assertEquals } from "../assert.ts";

const store = await import("../../web/ui/store.ts");
const projection = new store.PageProjection();
const { dirId } = await import("../../web/ui/directory.ts");

function setup() {
	projection.reset();
	const read = store.ensureRoom(projection, dirId("test-dir"), "read-room");
	const away = store.ensureRoom(projection, dirId("test-dir"), "away-room");
	projection.set({ activeKey: read.key, visible: true });
	return { read, away };
}

Deno.test("a line into the conversation being read keeps the unreads map", () => {
	const { read } = setup();
	const before = projection.get().unreads;
	store.deliver(projection, read.key, store.chatItem(projection, "alice", "hello", false));
	assertEquals(projection.get().unreads === before, true);
	assertEquals(store.historyOf(projection, read.key).length, 1);
});

Deno.test("a line into a background conversation changes the map and counts", () => {
	const { away } = setup();
	const before = projection.get().unreads;
	store.deliver(projection, away.key, store.chatItem(projection, "alice", "one", false));
	const once = projection.get().unreads;
	assertEquals(once === before, false);
	assertEquals(store.unreadOf(projection, away.key).kind, "unread");
	store.deliver(projection, away.key, store.chatItem(projection, "alice", "two", false));
	const unread = store.unreadOf(projection, away.key);
	assertEquals(unread.kind === "unread" && unread.count, 2);
	assertEquals(projection.get().unreads === once, false);
});

Deno.test("catching up removes the key", () => {
	const { away } = setup();
	store.deliver(projection, away.key, store.chatItem(projection, "alice", "one", false));
	assertEquals(projection.get().unreads.has(away.key), true);
	projection.set({ activeKey: away.key });
	store.markRead(projection, away.key);
	assertEquals(store.unreadOf(projection, away.key).kind, "rule-only");
	store.clearUnreadRule(projection, away.key);
	assertEquals(projection.get().unreads.has(away.key), false);
});
