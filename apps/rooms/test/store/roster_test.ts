// Roster projection updates membership and bridge attribution without replacing its conversation object.
/// <reference lib="dom" />
import "../support/browser_application.ts";

// Type-only, so it is erased rather than evaluated: every value import here is
// dynamic and below, because the store reads `matchMedia` as it loads.
import type { RoomMemberState } from "../../lib/room/presence.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({
		matches: false,
		addEventListener() {},
		removeEventListener() {},
	}),
});

const store = await import("../../web/ui/store.ts");
const projection = new store.PageProjection();
const { dirId } = await import("../../web/ui/types.ts");
const { assertEquals } = await import("../assert.ts");

function assert(ok: boolean, what: string): asserts ok {
	if (!ok) throw new Error(what);
}

function memberView(away: string): import("../../web/ui/store.ts").RoomViewUpdate {
	return {
		members: [["bob", { online: true, away }]],
		subject: null,
		lineBytes: null,
		bridge: null,
		carries: null,
		canSetSubject: false,
		canPostFiles: false,
		canModerate: false,
	};
}

Deno.test("roster-only snapshots do not replace the conversation", () => {
	projection.reset();
	const room = store.ensureRoom(projection, dirId("test-dir"), "roster-identity");
	const before = store.getConv(projection, room.key);
	store.setRoomView(projection, room.key, memberView(""));
	assert(store.getConv(projection, room.key) === before, "a join replaced the conversation");
	assertEquals([...store.membersOf(projection, room.key).keys()], ["bob"]);
	store.setRoomView(projection, room.key, memberView(""));
	assert(store.getConv(projection, room.key) === before, "a repeated join replaced the conversation");
	const roster = store.membersOf(projection, room.key);
	store.setRoomView(projection, room.key, memberView(""));
	assert(store.membersOf(projection, room.key) === roster, "a repeated join replaced the roster");
	store.setRoomView(projection, room.key, memberView("lunch"));
	assert(store.getConv(projection, room.key) === before, "an away word replaced the conversation");
	assertEquals(store.membersOf(projection, room.key).get("bob")?.away, "lunch");
});

Deno.test("an attached snapshot can refresh the roster without replacing the conversation", () => {
	projection.reset();
	const room = store.ensureRoom(projection, dirId("test-dir"), "roster-snapshot");
	store.setRoomMembership(projection, room.key, "joined");
	const before = store.getConv(projection, room.key);
	const shared = {
		subject: { description: "Shared work" },
		lineBytes: 4096,
		bridge: null,
		carries: { previews: true, typing: true },
		canSetSubject: true,
		canPostFiles: true,
		canModerate: true,
	};
	store.setRoomView(projection, room.key, { ...shared, members: [["ada", { online: true, away: "" }]] });
	const afterSubject = store.getConv(projection, room.key);
	assert(afterSubject !== before, "the first view left the joining conversation in place");
	assertEquals(afterSubject?.type === "room" ? afterSubject.subject?.description : null, "Shared work");
	const both: [string, RoomMemberState][] = [["ada", { online: true, away: "" }], ["bo", {
		online: true,
		away: "",
	}]];
	store.setRoomView(projection, room.key, { ...shared, members: both });
	assert(store.getConv(projection, room.key) === afterSubject, "a roster-only snapshot replaced the conversation");
	assertEquals([...store.membersOf(projection, room.key).keys()], ["ada", "bo"]);
	store.setRoomView(projection, room.key, { ...shared, members: both });
	assert(store.getConv(projection, room.key) === afterSubject, "an identical snapshot replaced the conversation");
});

// The bug this covers: a bridged room drew its foreign members under bare row
// keys after a reload, because bridge facts reached a live reader on the
// welcome line and an attached reader rebuilds from the snapshot instead.
Deno.test("an attached snapshot carries the bridge behind a room, and lets it go", () => {
	projection.reset();
	const room = store.ensureRoom(projection, dirId("test-dir"), "roster-bridge");
	store.setRoomMembership(projection, room.key, "joined");
	const view = {
		members: [["irc/ada", { online: true, away: "" }]] as [string, RoomMemberState][],
		subject: null,
		lineBytes: null,
		carries: null,
		canSetSubject: false,
		canPostFiles: false,
		canModerate: false,
	};
	const bridge = { prefix: "irc/", badge: "IRC", said: "Bridged from libera.", scope: "Libera" };
	store.setRoomView(projection, room.key, { ...view, bridge });
	const bridged = store.getConv(projection, room.key);
	assertEquals(bridged?.type === "room" ? bridged.bridge?.badge : null, "IRC");

	const again = store.getConv(projection, room.key);
	store.setRoomView(projection, room.key, { ...view, bridge: { ...bridge } });
	assert(store.getConv(projection, room.key) === again, "an equal bridge rewrote the conversation");

	// A room that stops naming a bridge has stopped being bridged. Leaving the
	// previous snapshot's facts standing would keep drawing badges for it.
	store.setRoomView(projection, room.key, { ...view, bridge: null });
	const plain = store.getConv(projection, room.key);
	assertEquals(plain?.type === "room" ? plain.bridge : "unset", undefined);
});

Deno.test("forgetting a conversation forgets who was in it", () => {
	projection.reset();
	const room = store.ensureRoom(projection, dirId("test-dir"), "roster-forget");
	store.setRoomView(projection, room.key, memberView(""));
	store.forgetConv(projection, room.key);
	assertEquals([...store.membersOf(projection, room.key)], []);
	store.setRoomView(projection, room.key, memberView(""));
	assertEquals([...store.membersOf(projection, room.key)], []);
});

// A subject that drops its link must not keep the old one, and a subject
// taken down leaves nothing behind.
Deno.test("a subject replaces its link exactly, and taking it down clears both", () => {
	projection.reset();
	const room = store.ensureRoom(projection, dirId("test-dir"), "subject-link");
	const subjectOf = () => {
		const conv = store.getConv(projection, room.key);
		return conv?.type === "room" ? conv.subject : null;
	};
	const board = "ocapn://host.tcp/s/Ym9hcmQ";
	store.setSubject(projection, room.key, { description: "the board", link: board });
	assertEquals(subjectOf(), { description: "the board", link: board });
	store.setSubject(projection, room.key, { description: "the board" });
	assertEquals(subjectOf(), { description: "the board" });
	store.setSubject(projection, room.key, { description: "the board", link: board });
	store.setSubject(projection, room.key, { description: "" });
	assertEquals(subjectOf(), undefined);
});
