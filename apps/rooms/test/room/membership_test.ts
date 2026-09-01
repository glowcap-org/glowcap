/// <reference lib="dom" />

import type { Room } from "../../lib/room/client.ts";
import type { Live } from "../../web/ui/net/live.ts";
import { assertEquals } from "../assert.ts";

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
Object.defineProperty(globalThis, "location", {
	configurable: true,
	value: { search: "", reload() {} },
});

const { retireRoomMembership } = await import("../../web/ui/net/room_membership.ts");
const { reenterRooms, retryRoom } = await import("../../web/ui/net/room_reentry.ts");
const { pickRoom, showRoom } = await import("../../web/ui/net/rooms.ts");
const { RoomsPage } = await import("../../web/ui/page.ts");
const store = await import("../../web/ui/store.ts");
const { dirId } = await import("../../web/ui/types.ts");

Deno.test("an ended room membership demotes the conversation and releases its local authority", () => {
	const page = new RoomsPage();
	page.projection.reset();
	const directory = dirId("ocapn://membership.id");
	store.openDir(page.projection, directory, "ocapn://membership.iroh");
	const conversation = store.ensureRoom(page.projection, directory, "general");
	store.setRoomMembership(page.projection, conversation.key, "joined");
	store.applyPresence(page.projection, conversation.key, { kind: "roster", names: ["ada", "bo"] });
	store.setGrants(page.projection, conversation.key, new Set(["topic", "steward"]));
	const sending = store.chatItem(page.projection, "ada", "still here?", true, "sending");
	const posted = { ...store.chatItem(page.projection, "ada", "earlier", true), lineId: 1 };
	store.deliver(page.projection, conversation.key, sending);
	store.deliver(page.projection, conversation.key, posted);
	let membershipReleased = 0;
	let lineReleased = 0;
	const room = { replaced: () => membershipReleased += 1 } as unknown as Room;
	const live = {
		page,
		id: directory,
		rooms: new Map([[conversation.key, room]]),
		standingTold: new Map([[conversation.key, "away"]]),
		refiling: new Map([[conversation.key, new Map([[1, []]])]]),
		echoes: [{ key: conversation.key, id: sending.id, attachmentIds: [], text: "still here?" }],
		posted: new Map([[posted.id, { release: () => lineReleased += 1 }]]),
	} as unknown as Live;
	page.live.dirs.set(directory, live);
	try {
		assertEquals(
			retireRoomMembership(page, conversation.key, room, "You are no longer in this room."),
			true,
		);
		const retired = store.getConv(page.projection, conversation.key);
		assertEquals(retired?.type === "room" ? retired.membership : null, "unavailable");
		assertEquals(retired?.type === "room" ? [...retired.grants] : [], []);
		assertEquals(retired?.type === "room" ? [...store.membersOf(page.projection, conversation.key)] : [], []);
		const history = store.historyOf(page.projection, conversation.key);
		const retiredSend = history.find((line) => line.id === sending.id);
		const retiredLine = history.find((line) => line.id === posted.id);
		assertEquals(retiredSend?.kind === "chat" ? retiredSend.state : null, "failed");
		assertEquals(retiredLine?.kind === "chat" ? retiredLine.lineId : null, undefined);
		assertEquals(history.at(-1)?.text, "You are no longer in this room.");
		assertEquals(live.rooms.size, 0);
		assertEquals(live.echoes, []);
		assertEquals(live.refiling.size, 0);
		assertEquals(live.posted.size, 0);
		assertEquals(membershipReleased, 1);
		assertEquals(lineReleased, 1);
		assertEquals(retireRoomMembership(page, conversation.key, room, "duplicate"), false);
	} finally {
		page.live.dirs.delete(directory);
		page.projection.reset();
	}
});

Deno.test("a disconnected room selects without coupling the rail press to rejoin", () => {
	const page = new RoomsPage();
	page.projection.reset();
	const directory = dirId("ocapn://selection.id");
	store.openDir(page.projection, directory, "ocapn://selection.iroh");
	const first = store.ensureRoom(page.projection, directory, "first");
	const waiting = store.ensureRoom(page.projection, directory, "waiting");
	store.setRoomMembership(page.projection, first.key, "joined");
	store.setRoomMembership(page.projection, waiting.key, "unavailable");
	store.switchTo(page.projection, first.key);
	page.live.dirs.set(directory, {
		page,
		id: directory,
		rooms: new Map([[first.key, {} as Room]]),
	} as unknown as Live);
	try {
		pickRoom(page, directory, waiting.id, waiting.key);
		assertEquals(page.projection.get().activeKey, waiting.key);
		const selected = store.getConv(page.projection, waiting.key);
		assertEquals(selected?.type === "room" ? selected.membership : null, "unavailable");
	} finally {
		page.live.dirs.delete(directory);
		page.projection.reset();
	}
});

Deno.test("a bridged room selects by name without starting a second join", () => {
	const page = new RoomsPage();
	page.projection.reset();
	const directory = dirId("ocapn://bridge-selection.id");
	store.openDir(page.projection, directory, "ocapn://bridge-selection.iroh");
	store.patchDir(page.projection, directory, { requestedNick: "ada" });
	store.setLiveRoom(page.projection, directory, {
		id: "new-gen",
		name: "network-channel",
		kind: "bridge",
		count: null,
		origin: "irc.example:6697",
		proof: "bridge",
		offers: "participant",
	});
	const waiting = store.ensureRoom(page.projection, directory, "network-channel", {
		publicationId: "old-gen",
		membership: "unavailable",
	});
	page.live.dirs.set(directory, {
		page,
		id: directory,
		rooms: new Map(),
	} as unknown as Live);
	try {
		showRoom(page, directory, waiting.id, "press");
		assertEquals(page.projection.get().activeKey, waiting.key);
		const selected = store.getConv(page.projection, waiting.key);
		assertEquals(selected?.type === "room" ? selected.membership : null, "unavailable");
		assertEquals(store.existingRoom(page.projection, directory, waiting.id)?.key, waiting.key);
	} finally {
		page.live.dirs.delete(directory);
		page.projection.reset();
	}
});

Deno.test("directory reconstruction without a nickname leaves listed rooms unjoined", () => {
	const page = new RoomsPage();
	page.projection.reset();
	const directory = dirId("ocapn://reentry.id");
	store.openDir(page.projection, directory, "ocapn://reentry.iroh");
	const listed = store.ensureRoom(page.projection, directory, "general", { membership: "unavailable" });
	const bridged = store.ensureRoom(page.projection, directory, "network-channel", {
		publicationId: "bridge-gen",
		membership: "unavailable",
	});
	assertEquals(reenterRooms(page, directory), false);
	const listedAfter = store.getConv(page.projection, listed.key);
	const bridgedAfter = store.getConv(page.projection, bridged.key);
	assertEquals(listedAfter?.type === "room" ? listedAfter.membership : null, "unavailable");
	assertEquals(bridgedAfter?.type === "room" ? bridgedAfter.membership : null, "unavailable");
	page.projection.reset();
});

Deno.test("a room that needs an explicit rejoin is not reconstructed in the background", () => {
	const page = new RoomsPage();
	page.projection.reset();
	const directory = dirId("ocapn://manual-reentry.id");
	store.openDir(page.projection, directory, "ocapn://manual-reentry.iroh");
	store.patchDir(page.projection, directory, { requestedNick: "ada" });
	const manual = store.ensureRoom(page.projection, directory, "rejoin", {
		reconnect: "manual",
		membership: "unavailable",
	});
	assertEquals(reenterRooms(page, directory), false);
	const after = store.getConv(page.projection, manual.key);
	assertEquals(after?.type === "room" ? after.membership : null, "unavailable");
	page.projection.reset();
});

Deno.test("retrying a listed room without a nickname opens the join card as its gate", async () => {
	const page = new RoomsPage();
	page.projection.reset();
	const directory = dirId("ocapn://nameless.id");
	store.openDir(page.projection, directory, "ocapn://nameless.iroh");
	const waiting = store.ensureRoom(page.projection, directory, "general", { membership: "unavailable" });
	store.switchTo(page.projection, waiting.key);
	assertEquals(await retryRoom(page, waiting.key), "");
	assertEquals(page.projection.get().activeKey, null);
	assertEquals(page.projection.get().reaching.room?.value, waiting.id);
	assertEquals(page.projection.get().reaching.source, "press");
	const selected = store.getConv(page.projection, waiting.key);
	assertEquals(selected?.type === "room" ? selected.membership : null, "unavailable");
	page.projection.reset();
});

Deno.test("retrying a private room without a nickname gates the join card on its link", async () => {
	const page = new RoomsPage();
	page.projection.reset();
	const directory = dirId("ocapn://private-nameless.id");
	store.openDir(page.projection, directory, "ocapn://private-nameless.iroh");
	const waiting = store.ensureRoom(page.projection, directory, "plans", {
		held: true,
		link: "ocapn://private-nameless.iroh/s/plans",
		membership: "unavailable",
	});
	store.switchTo(page.projection, waiting.key);
	assertEquals(await retryRoom(page, waiting.key), "");
	assertEquals(page.projection.get().activeKey, null);
	assertEquals(page.projection.get().reaching.locator?.value, "ocapn://private-nameless.iroh/s/plans");
	page.projection.reset();
});
