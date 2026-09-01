// The attached view routes every act through its durable session: DM
// creation, joins, selection, moderation, and the bridge form, with the
// shared snapshot as the one authority the page projects.

/// <reference lib="dom" />

import type { RoomsSessionSnapshot } from "../../lib/session/client.ts";
import { emptyRoomsSessionState, type RoomsSessionState } from "../../lib/rooms_state.ts";
import type { RoomsBrowserController } from "../../web/ui/controller/browser.ts";
import { assertEquals } from "../assert.ts";
import { registrationId } from "../support/registration.ts";
import { roomsSessionSnapshot } from "../support/session_snapshot.ts";
import { formatRoomsSturdyref, roomsLocator } from "../../lib/locator.ts";
import {
	addActiveDm,
	addDmDirectory,
	attachedCommandPowers,
	createAttachedRoomsSession,
	dirId,
	FakeController,
	resetStore,
	RoomsPage,
	sessionFor,
	snapshot,
	store,
	waitForDraftSave,
} from "./semantics_support.ts";

class ProjectingJoinController extends FakeController {
	readonly #page: InstanceType<typeof RoomsPage>;

	constructor(current: RoomsSessionSnapshot, page: InstanceType<typeof RoomsPage>) {
		super(current);
		this.#page = page;
	}

	override joinRoom(
		room: Extract<RoomsSessionState["conversations"][number], { kind: "room" }>,
		directory?: { locator: string; nick: string },
	): Promise<RoomsSessionSnapshot> {
		void super.joinRoom(room, directory);
		store.ensureRoom(this.#page.projection, dirId(room.directory), room.name, { persistId: room.id });
		this.current = {
			...this.current,
			revision: this.current.revision + 1,
			checkpoint: { ...this.current.checkpoint, active: room.id },
		};
		return Promise.resolve(this.current);
	}
}

class SelectionRaceController extends FakeController {
	readonly #newerActive: string;

	constructor(current: RoomsSessionSnapshot, newerActive: string) {
		super(current);
		this.#newerActive = newerActive;
	}

	override select(id: string): Promise<RoomsSessionSnapshot> {
		const selected = super.select(id);
		this.current = {
			...this.current,
			revision: this.current.revision + 1,
			checkpoint: { ...this.current.checkpoint, active: this.#newerActive },
		};
		return selected;
	}
}

class SettledSelectionController extends FakeController {
	override select(id: string): Promise<RoomsSessionSnapshot> {
		void super.select(id);
		this.current = {
			...this.current,
			revision: this.current.revision + 1,
			checkpoint: { ...this.current.checkpoint, active: id },
		};
		return Promise.resolve(this.current);
	}
}

Deno.test("attached DM creation opens the conversation in one command", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addDmDirectory(page);
	const controller = new FakeController();
	sessionFor(page, controller).startDm("bo");
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(controller.directIds.length, 1);
	assertEquals(controller.selectedIds, []);
});

Deno.test("attached room links remain room authority instead of directory locators", async () => {
	const page = new RoomsPage();
	resetStore(page);
	const controller = new FakeController();
	const link = formatRoomsSturdyref(roomsLocator("127.0.0.1:4321"), "room-link");
	assertEquals(await sessionFor(page, controller).join({ room: "backroom", locator: link }, "ada"), "");
	assertEquals(controller.joinedRooms.length, 1);
	assertEquals(controller.joinedRooms[0], {
		room: {
			kind: "room",
			id: controller.joinedRooms[0]?.room.id,
			directory: "ocapn://127.0.0.1%3A4321.tcp",
			name: "backroom",
			held: true,
			link,
			standing: null,
			draft: "",
		},
		directory: { locator: "127.0.0.1:4321", nick: "ada" },
	});
});

Deno.test("attached command DM creation opens the conversation in one command", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addDmDirectory(page);
	const controller = new FakeController();
	const powers = attachedCommandPowers(
		page.projection,
		controller as unknown as import("../../web/ui/session/attached.ts").AttachedRoomsController,
		{} as RoomsBrowserController,
		() => {},
	);
	powers.directMessage("bo");
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(controller.directIds.length, 1);
	assertEquals(controller.selectedIds, []);
});

Deno.test("attached DM creation reuses an existing open conversation", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addDmDirectory(page);
	const controller = new FakeController(snapshot({
		...emptyRoomsSessionState(),
		directories: [{
			id: "directory",
			locator: "127.0.0.1:1",
			home: true,
			nick: "ada",
			standing: null,
		}],
		conversations: [{
			kind: "direct",
			id: "existing-direct",
			directory: "directory",
			peer: "bo",
			peerRegistrationId: registrationId(1),
			closed: false,
			draft: "",
		}],
		active: null,
	}));
	sessionFor(page, controller).startDm("BO");
	const powers = attachedCommandPowers(
		page.projection,
		controller as unknown as import("../../web/ui/session/attached.ts").AttachedRoomsController,
		{} as RoomsBrowserController,
		() => {},
	);
	powers.directMessage("bo");
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(controller.directIds, []);
	assertEquals(controller.selectedIds, ["existing-direct", "existing-direct"]);
});

Deno.test("attached DM removal forgets live and closed conversations in one act", async () => {
	const page = new RoomsPage();
	resetStore(page);
	const controller = new FakeController();
	const session = sessionFor(page, controller);
	const directory = dirId("directory");
	const live = store.ensureDm(page.projection, directory, "bo", registrationId(1));
	const closed = store.restoreDm(page.projection, directory, "cy", registrationId(2), "closed-direct", true);
	if (live == null || closed == null) throw new Error("the direct fixtures were not created");
	session.closeDm(live);
	session.closeDm(closed);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(controller.removedConversationIds, [live.persistId, closed.persistId]);
});

Deno.test("attached /quit retires its staged draft before removing the directory", async () => {
	const page = new RoomsPage();
	resetStore(page);
	addActiveDm(page);
	const controller = new FakeController();
	const session = sessionFor(page, controller);
	const conversation = store.activeConv(page.projection);
	if (conversation == null || conversation.type === "directory") {
		throw new Error("the quit fixture has no active conversation");
	}
	session.setDraft("/quit");
	session.send();
	await waitForDraftSave();
	assertEquals(controller.removedDirectoryIds, [conversation.dir]);
	assertEquals(controller.draftWrites.length, 0);
	assertEquals(controller.stagedDrafts.has(conversation.persistId), false);
});

Deno.test("attached ignore and unignore wait for the shared snapshot", () => {
	const page = new RoomsPage();
	resetStore(page);
	const controller = new FakeController();
	const powers = attachedCommandPowers(
		page.projection,
		controller as unknown as import("../../web/ui/session/attached.ts").AttachedRoomsController,
		{} as RoomsBrowserController,
		() => {},
	);
	page.projection.set({ ignored: new Set(["bo"]) });
	powers.ignore("cy");
	assertEquals([...page.projection.get().ignored], ["bo"]);
	powers.unignore("bo");
	assertEquals([...page.projection.get().ignored], ["bo"]);
	assertEquals(controller.commandNames, ["setIgnoredNames", "setIgnoredNames"]);
});

Deno.test("attached public join submits one complete room intent", async () => {
	const page = new RoomsPage();
	resetStore(page);
	const controller = new ProjectingJoinController(snapshot(), page);
	const session = createAttachedRoomsSession(
		page,
		{} as RoomsBrowserController,
		controller as unknown as import("../../web/ui/session/attached.ts").AttachedRoomsController,
		{} as import("../../web/ui/session/attached_files.ts").AttachedSessionFiles,
		{ defaultDirectoryLocator: "127.0.0.1:1" },
	);
	assertEquals(await session.join({ room: "general", locator: "", hidden: false }, "ada"), "");
	assertEquals(controller.joinedRooms.length, 1);
	assertEquals(controller.joinedRooms[0].room.name, "general");
	assertEquals(controller.joinedRooms[0].directory, { locator: "127.0.0.1:1", nick: "ada" });
	assertEquals(controller.commandNames, []);
	const joined = [...page.projection.get().convs.values()].find((conversation) =>
		conversation.type !== "directory" && conversation.persistId === controller.current.checkpoint.active
	);
	assertEquals(page.projection.get().activeKey, joined?.key);
});

Deno.test("an attached room with retired authority opens its explicit recovery surface", async () => {
	const page = new RoomsPage();
	resetStore(page);
	const checkpoint = {
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [{
			kind: "room" as const,
			id: "retired-room",
			directory: "directory",
			name: "general",
			held: false,
			reconnect: "manual" as const,
			standing: null,
			draft: "",
		}],
	};
	const controller = new FakeController(snapshot(checkpoint));
	const session = sessionFor(page, controller);
	const room = store.ensureRoom(page.projection, dirId("directory"), "general", { persistId: "retired-room" });
	assertEquals(controller.joinedRooms.length, 0);
	session.openConv(room.key);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(controller.joinedRooms, []);
	assertEquals(controller.selectedIds, ["retired-room"]);
});

Deno.test("attached rail presses leave route-level screens after an idempotent shared selection", async () => {
	const page = new RoomsPage();
	resetStore(page);
	const directory = dirId("directory");
	const direct = {
		kind: "direct" as const,
		id: "direct-id",
		directory: "directory",
		peer: "bo",
		peerRegistrationId: registrationId(1),
		closed: false,
		draft: "",
	};
	const room = {
		kind: "room" as const,
		id: "room-id",
		directory: "directory",
		name: "general",
		held: false,
		standing: null,
		draft: "",
	};
	const initial = snapshot({
		...emptyRoomsSessionState(),
		directories: [{ id: "directory", locator: "127.0.0.1:1", home: true, nick: "ada", standing: null }],
		conversations: [room, direct],
		active: room.id,
	});
	const controller = new SettledSelectionController(initial);
	const roomView = store.ensureRoom(page.projection, directory, room.name, { persistId: room.id });
	const directView = store.restoreDm(
		page.projection,
		directory,
		direct.peer,
		direct.peerRegistrationId,
		direct.id,
		false,
	);
	if (directView == null) throw new Error("the attached rail fixture created no direct conversation");
	const session = sessionFor(page, controller);
	store.clearConv(page.projection);
	session.pickRoom(directory, room.name, roomView.key);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(page.projection.get().activeKey, roomView.key);
	store.clearConv(page.projection);
	session.openConv(directView.key);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(page.projection.get().activeKey, directView.key);
	assertEquals(controller.selectedIds, [room.id, direct.id]);

	const raced = new SelectionRaceController(initial, direct.id);
	store.clearConv(page.projection);
	sessionFor(page, raced).pickRoom(directory, room.name, roomView.key);
	await new Promise((resolve) => setTimeout(resolve, 0));
	assertEquals(page.projection.get().activeKey, null);
});

Deno.test("attached IRC identity answers from committed intent while live state remains reactive", async () => {
	const page = new RoomsPage();
	resetStore(page);
	const directory = dirId("directory");
	page.projection.set({
		dirs: new Map([[
			directory,
			{
				id: directory,
				locator: "127.0.0.1:1",
				liveRooms: new Map(),
				dmablePeers: new Map(),
				requestedNick: "ada",
				nick: "ada",
				slot: 1,
				reached: true,
				session: "connected",
				statusText: "",
				dmUnreachable: "",
				standing: null,
			},
		]]),
		homeDir: directory,
	});
	const room = store.ensureRoom(page.projection, directory, "bridge", { persistId: "room-id" });
	const controller = new FakeController(roomsSessionSnapshot({
		issues: [{ subject: "room-bridge:directory:room-id", reason: "IRC refused the registered nickname" }],
	}));
	assertEquals(
		await sessionFor(page, controller).submitBridgeForm(room.key, "Libera", "link", { nick: "ada" }, {}),
		"",
	);
	assertEquals(controller.bridgeForms, [{ scope: "Libera", action: "link" }]);
});

Deno.test("attached room moderation passes the pasted sturdyref unchanged", async () => {
	const page = new RoomsPage();
	resetStore(page);
	const directory = dirId("directory");
	const room = store.ensureRoom(page.projection, directory, "general", { persistId: "room-id" });
	const controller = new FakeController();
	const sturdyref = "ocapn://moderator.example/s/room-authority";
	await sessionFor(page, controller).stewardRoom(room.key, sturdyref);
	assertEquals(controller.moderatorRequests, [{ conversationId: "room-id", sturdyref }]);
});
