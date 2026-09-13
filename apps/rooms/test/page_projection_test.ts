// Each page projection owns its drafts, conversations, roster, history, and unread state independently.
import "./support/browser_application.ts";
// Two pages in one isolate keep separate presentation. Drafts, conversations,
// rosters, histories, unreads, and who is composing belong to the page that wrote them.

/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

const store = await import("../web/ui/store.ts");
const { RoomsPage } = await import("../web/ui/page.ts");
const { dirId } = await import("../web/ui/types.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

Deno.test("two pages do not share drafts, conversations, members, typers, histories, or unreads", () => {
	const first = new RoomsPage();
	const second = new RoomsPage();
	const directory = dirId("isolation-dir");
	store.openDir(first.projection, directory, "ocapn://isolation.iroh");
	const room = store.ensureRoom(first.projection, directory, "general");
	store.switchTo(first.projection, room.key);
	store.setDraft(first.projection, "only on the first page");
	store.setRoomView(first.projection, room.key, {
		members: [["ada", { online: true, away: "" }]],
		topic: null,
		lineBytes: null,
		bridge: null,
		carries: null,
		canSetTopic: false,
		canPostFiles: false,
		canModerate: false,
	});
	store.setTyper(first.projection, room.key, "ada", true);
	store.deliver(first.projection, room.key, store.chatItem(first.projection, "ada", "hello", false));
	const waiting = store.ensureRoom(first.projection, directory, "side");
	store.deliver(first.projection, waiting.key, store.chatItem(first.projection, "ada", "waiting", false));

	assert(second.projection.get().convs.size === 0, "the second page inherited the first page's conversations");
	assert(second.projection.get().drafts.size === 0, "the second page inherited the first page's drafts");
	assert(
		store.membersOf(second.projection, room.key).size === 0,
		"the second page inherited the first page's roster",
	);
	assert(
		store.typersOf(second.projection, room.key).size === 0,
		"the second page inherited who is composing on the first",
	);
	assert(
		store.historyOf(second.projection, room.key).length === 0,
		"the second page inherited the first page's history",
	);
	assert(
		store.unreadOf(second.projection, waiting.key).kind === "caught-up",
		"the second page inherited the first page's unread",
	);
	assert(store.activeDraft(first.projection).text === "only on the first page", "the first page lost its own draft");
	assert(store.membersOf(first.projection, room.key).has("ada"), "the first page lost its own roster");
	assert(store.typersOf(first.projection, room.key).has("ada"), "the first page lost who is composing");
	assert(store.historyOf(first.projection, room.key).length === 1, "the first page lost its own history");
	assert(store.unreadOf(first.projection, waiting.key).kind === "unread", "the first page lost its own unread");
});
